import XCTest
@testable import Geo

final class FilesAreTruthMigrationRunnerTests: XCTestCase {

    private var tempRoot: URL!
    private var dataDir: URL!
    private var backupDir: URL!
    private var defaults: UserDefaults!
    private var fileService: BlockFileService!
    private var database: DatabaseService!
    private var backupService: BackupService!

    private let masterEnabled = "geo.migration.filesAreTruth.enabled"
    private let masterDone = "geo.migration.filesAreTruth.done"

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-runner-tests-\(UUID().uuidString)", isDirectory: true)
        dataDir = tempRoot.appendingPathComponent("Geo", isDirectory: true)
        backupDir = tempRoot.appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

        defaults = UserDefaults(suiteName: "runner-tests-\(UUID().uuidString)")!
        fileService = BlockFileService(baseURL: dataDir)
        try fm.createDirectory(at: fileService.blocksDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDir.appendingPathComponent("Index"), withIntermediateDirectories: true)
        database = DatabaseService(databaseURL: dataDir.appendingPathComponent("Index/blocks.sqlite"), fileManager: fm)
        backupService = BackupService(dataDirectory: dataDir)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil; dataDir = nil; backupDir = nil; defaults = nil
        fileService = nil; database = nil; backupService = nil
        try await super.tearDown()
    }

    private func makeRunner() -> FilesAreTruthMigrationRunner {
        FilesAreTruthMigrationRunner(
            userDefaults: defaults,
            backupService: backupService,
            phase0: Phase0FrontmatterReinjectionMigration(userDefaults: defaults),
            phase1: Phase1LayerBackfillMigration(userDefaults: defaults),
            phase2: Phase2TagBackfillMigration(userDefaults: defaults),
            phase3: Phase3DayLinkBackfillMigration(userDefaults: defaults)
        )
    }

    @discardableResult
    private func writeBlock(_ name: String, content: String) throws -> URL {
        let url = fileService.blocksDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func seedRow(id: String, layer: String = "agent") async throws {
        let entry = BlockIndexEntry(
            id: id, path: id, title: id, content: "",
            createdAt: Date(), modifiedAt: Date(),
            tagId: nil, dayId: nil, openTaskCount: 0, completedTaskCount: 0,
            tags: [], type: "fleeting", status: nil, layer: layer, isFullWidth: false
        )
        try await database.upsertBlock(entry)
    }

    private func backupCount() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("Geo-Backup-") }.count
    }

    private func run(_ runner: FilesAreTruthMigrationRunner) async {
        await runner.runIfEnabled(
            fileService: fileService,
            database: database,
            recordWrite: { _ in },
            backupDirectory: backupDir
        )
    }

    func testDefaultOffIsNoOp() async throws {
        try writeBlock("A.md", content: "# A\n")
        try await seedRow(id: "A.md")
        let runner = makeRunner()

        await run(runner)

        XCTAssertFalse(runner.didRunThisLaunch)
        XCTAssertFalse(runner.didBackup)
        XCTAssertFalse(defaults.bool(forKey: masterDone))
        XCTAssertEqual(backupCount(), 0, "No backup taken when master switch is OFF")
        XCTAssertFalse(defaults.bool(forKey: Phase0FrontmatterReinjectionMigration().doneKey))
    }

    func testAbortIfEmptyTakesNoBackupAndDoesNotMarkDone() async throws {
        // Master ON but zero metadata rows -> abort loudly before backup.
        defaults.set(true, forKey: masterEnabled)
        let runner = makeRunner()

        await run(runner)

        XCTAssertFalse(runner.didRunThisLaunch)
        XCTAssertFalse(runner.didBackup)
        XCTAssertFalse(defaults.bool(forKey: masterDone))
        XCTAssertEqual(backupCount(), 0, "Abort-if-empty must not take a backup")
    }

    func testHappyPathBacksUpFirstThenRunsPhasesIdempotently() async throws {
        try writeBlock("A.md", content: "---\ntype: fleeting\n---\n# A\n")
        try await seedRow(id: "A.md", layer: "agent")
        defaults.set(true, forKey: masterEnabled)
        let runner = makeRunner()
        var reloadCount = 0
        let hooks = FilesAreTruthMigrationRunner.Hooks(
            reloadAndRebuild: { reloadCount += 1 },
            refreshDays: {}
        )

        await runner.runIfEnabled(
            fileService: fileService,
            database: database,
            recordWrite: { _ in },
            backupDirectory: backupDir,
            hooks: hooks
        )

        XCTAssertTrue(runner.didBackup, "Backup must be taken before any phase runs")
        XCTAssertEqual(backupCount(), 1, "Exactly one whole-state backup before the run")
        XCTAssertTrue(runner.didRunThisLaunch)
        XCTAssertTrue(defaults.bool(forKey: masterDone))
        // Phase0 ran (forced-enabled by the runner) and reinjected layer into frontmatter.
        XCTAssertTrue(defaults.bool(forKey: Phase0FrontmatterReinjectionMigration().doneKey))
        let after = try String(contentsOf: fileService.blocksDirectory.appendingPathComponent("A.md"), encoding: .utf8)
        XCTAssertEqual(MarkdownConverter.shared.layer(in: after), .agent)
        XCTAssertGreaterThan(reloadCount, 0, "reloadAndRebuild invoked after a phase that did work")

        // Idempotent re-run: master done -> no second backup, no further work.
        let backupsAfterFirst = backupCount()
        await run(runner)
        XCTAssertEqual(backupCount(), backupsAfterFirst, "Re-run must not produce another backup")
    }
}
