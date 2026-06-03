import XCTest
@testable import Geo

final class BackupServiceTests: XCTestCase {
    private var root: URL!
    private var dataDir: URL!
    private var exportDir: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupServiceTests-\(UUID().uuidString)", isDirectory: true)
        dataDir = root.appendingPathComponent("Geo", isDirectory: true)
        exportDir = root.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        dataDir = nil
        exportDir = nil
        super.tearDown()
    }

    private func makeEntry(id: String, title: String, content: String) -> BlockIndexEntry {
        BlockIndexEntry(
            id: id,
            path: "/tmp/\(id).md",
            title: title,
            content: content,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            tagId: nil,
            dayId: nil,
            openTaskCount: 0,
            completedTaskCount: 0,
            tags: []
        )
    }

    private func seedDataDir() async throws {
        let blocks = dataDir.appendingPathComponent("Blocks", isDirectory: true)
        let index = dataDir.appendingPathComponent("Index", isDirectory: true)
        let tasks = dataDir.appendingPathComponent("Tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: blocks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)

        try "# Alpha\n\nbody".write(to: blocks.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        try "# Beta\n\nbody".write(to: blocks.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
        try "{\"work\":\"#0055FF\"}".write(to: dataDir.appendingPathComponent("tags.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: dataDir.appendingPathComponent("days.json"), atomically: true, encoding: .utf8)

        let db = DatabaseService(databaseURL: index.appendingPathComponent("blocks.sqlite"))
        try await db.upsertBlock(makeEntry(id: "alpha", title: "Alpha", content: "body"))
    }

    func testExportProducesDatedArchive() async throws {
        try await seedDataDir()
        let service = BackupService(dataDirectory: dataDir)
        let url = try service.exportArchive(to: exportDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let pattern = #"^Geo-Backup-\d{8}-\d{6}\.zip$"#
        XCTAssertNotNil(url.lastPathComponent.range(of: pattern, options: .regularExpression),
                        "Unexpected archive name: \(url.lastPathComponent)")
    }

    func testValidateArchiveReturnsCounts() async throws {
        try await seedDataDir()
        let service = BackupService(dataDirectory: dataDir)
        let url = try service.exportArchive(to: exportDir)

        let info = try service.validateArchive(at: url)
        XCTAssertEqual(info.blockCount, 2)
        XCTAssertTrue(info.hasTasks)
        XCTAssertTrue(info.hasTags)
    }

    func testValidateArchiveCountsNestedLayerFoldersRecursively() async throws {
        let blocks = dataDir.appendingPathComponent("Blocks", isDirectory: true)
        let index = dataDir.appendingPathComponent("Index", isDirectory: true)
        let nestedVoce = blocks.appendingPathComponent("Voce/MOC", isDirectory: true)
        let nestedAgente = blocks.appendingPathComponent("Agente", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedVoce, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedAgente, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)

        try "# Flat".write(to: blocks.appendingPathComponent("flat.md"), atomically: true, encoding: .utf8)
        try "# Nested A".write(to: nestedVoce.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# Nested B".write(to: nestedAgente.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "{\"work\":\"#0055FF\"}".write(to: dataDir.appendingPathComponent("tags.json"), atomically: true, encoding: .utf8)
        let db = DatabaseService(databaseURL: index.appendingPathComponent("blocks.sqlite"))
        try await db.upsertBlock(makeEntry(id: "flat", title: "Flat", content: "body"))

        let service = BackupService(dataDirectory: dataDir)
        let url = try service.exportArchive(to: exportDir)

        let info = try service.validateArchive(at: url)
        XCTAssertEqual(info.blockCount, 3, "Block count must recurse into nested layer folders")
        XCTAssertTrue(info.hasTags)
    }

    func testValidateArchiveRejectsMissingIndex() async throws {
        let blocks = dataDir.appendingPathComponent("Blocks", isDirectory: true)
        try FileManager.default.createDirectory(at: blocks, withIntermediateDirectories: true)
        try "# x".write(to: blocks.appendingPathComponent("x.md"), atomically: true, encoding: .utf8)

        let service = BackupService(dataDirectory: dataDir)
        let url = try service.exportArchive(to: exportDir)

        XCTAssertThrowsError(try service.validateArchive(at: url)) { error in
            XCTAssertEqual(error as? BackupError, .invalidArchive)
        }
    }

    func testFullRoundTrip() async throws {
        try await seedDataDir()
        let originalTags = try Data(contentsOf: dataDir.appendingPathComponent("tags.json"))
        let originalAlpha = try String(contentsOf: dataDir.appendingPathComponent("Blocks/alpha.md"), encoding: .utf8)

        let service = BackupService(dataDirectory: dataDir)
        let url = try service.exportArchive(to: exportDir)

        try FileManager.default.removeItem(at: dataDir.appendingPathComponent("Blocks/beta.md"))
        try "MUTATED".write(to: dataDir.appendingPathComponent("Blocks/alpha.md"), atomically: true, encoding: .utf8)

        try service.stageRestore(from: url)
        XCTAssertTrue(service.applyPendingRestoreIfNeeded())

        let restoredAlpha = try String(contentsOf: dataDir.appendingPathComponent("Blocks/alpha.md"), encoding: .utf8)
        let restoredTags = try Data(contentsOf: dataDir.appendingPathComponent("tags.json"))
        XCTAssertEqual(restoredAlpha, originalAlpha)
        XCTAssertEqual(restoredTags, originalTags)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("Blocks/beta.md").path))

        let restoredDB = DatabaseService(databaseURL: dataDir.appendingPathComponent("Index/blocks.sqlite"))
        let blocks = try await restoredDB.fetchAllBlocks()
        XCTAssertEqual(blocks.map { $0.id }.sorted(), ["alpha"])
        XCTAssertEqual(blocks.first?.title, "Alpha")
    }

    func testRestoreKeepsPreRestoreSnapshot() async throws {
        try await seedDataDir()
        let service = BackupService(dataDirectory: dataDir)
        let url = try service.exportArchive(to: exportDir)

        try "SENTINEL".write(to: dataDir.appendingPathComponent("Blocks/alpha.md"), atomically: true, encoding: .utf8)

        try service.stageRestore(from: url)
        XCTAssertTrue(service.applyPendingRestoreIfNeeded())

        let snapshots = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Geo.pre-restore-") }
        XCTAssertEqual(snapshots.count, 1)
        let snapshotAlpha = try String(contentsOf: snapshots[0].appendingPathComponent("Blocks/alpha.md"), encoding: .utf8)
        XCTAssertEqual(snapshotAlpha, "SENTINEL")
    }

    func testApplyPendingRestoreNoMarkerIsNoOp() throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let service = BackupService(dataDirectory: dataDir)
        XCTAssertFalse(service.applyPendingRestoreIfNeeded())
    }
}
