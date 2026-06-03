import XCTest
@testable import Geo

final class Phase1LayerBackfillTests: XCTestCase {

    private var tempRoot: URL!
    private var defaults: UserDefaults!
    private var fileService: BlockFileService!
    private var database: DatabaseService!

    private let enabledKey = "geo.migration.phase1.backfillLayer"
    private let doneKey = "geo.migration.phase1.backfillLayer.done"

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-phase1-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let suiteName = "phase1-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!

        fileService = BlockFileService(baseURL: tempRoot)
        database = DatabaseService(databaseURL: tempRoot.appendingPathComponent("index.sqlite"), fileManager: fm)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        defaults = nil
        fileService = nil
        database = nil
        try await super.tearDown()
    }

    @discardableResult
    private func writeBlock(_ name: String, content: String) throws -> URL {
        let url = fileService.blocksDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func seedRow(id: String, layer: String = "user") async throws {
        let entry = BlockIndexEntry(
            id: id,
            path: id,
            title: id,
            content: "",
            createdAt: Date(),
            modifiedAt: Date(),
            tagId: nil,
            dayId: nil,
            openTaskCount: 0,
            completedTaskCount: 0,
            tags: [],
            type: "fleeting",
            status: nil,
            layer: layer,
            isFullWidth: false
        )
        try await database.upsertBlock(entry)
    }

    private func run() async {
        await Phase1LayerBackfillMigration(userDefaults: defaults).runIfEnabled(
            fileService: fileService,
            database: database,
            recordWrite: { _ in }
        )
    }

    func testDefaultOffWritesNothing() async throws {
        let original = "# Title\n\nBody.\n"
        let url = try writeBlock("A.md", content: original)
        try await seedRow(id: "A.md", layer: "agent")
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, original)
        XCTAssertFalse(defaults.bool(forKey: doneKey))
    }

    func testEnabledWritesLayerFromSQLite() async throws {
        defaults.set(true, forKey: enabledKey)
        let url = try writeBlock("B.md", content: "---\ntype: fleeting\n---\n# B\n")
        try await seedRow(id: "B.md", layer: "agent")
        await run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "No file move")
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(MarkdownConverter.shared.parse(after).frontmatter["layer"], "agent")
        XCTAssertTrue(defaults.bool(forKey: doneKey))
    }

    func testSkipsBlocksAlreadyHavingLayer() async throws {
        defaults.set(true, forKey: enabledKey)
        let url = try writeBlock("C.md", content: "---\nlayer: shared\ntype: fleeting\n---\n# C\n")
        try await seedRow(id: "C.md", layer: "agent")
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(MarkdownConverter.shared.parse(after).frontmatter["layer"], "shared",
                       "Frontmatter wins; backfill only fills missing layer")
    }

    func testCopiesColumnVerbatimNeverDefaultsToUser() async throws {
        defaults.set(true, forKey: enabledKey)
        let url = try writeBlock("D.md", content: "---\ntype: fleeting\n---\n# D\n")
        try await seedRow(id: "D.md", layer: "review")
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(MarkdownConverter.shared.parse(after).frontmatter["layer"], "review",
                       "Must copy the SQLite column verbatim, not default to user")
    }

    func testAbortOnEmptyDatabase() async throws {
        defaults.set(true, forKey: enabledKey)
        let original = "# Untouched\n"
        let url = try writeBlock("E.md", content: original)
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, original)
        XCTAssertFalse(defaults.bool(forKey: doneKey))
    }

    func testPreservesExistingFrontmatter() async throws {
        defaults.set(true, forKey: enabledKey)
        let body = "# F\n\nBody.\n"
        let url = try writeBlock("F.md", content: "---\nid: ABC\ntype: permanent\nstatus: evergreen\ntags: [arc]\n---\n" + body)
        try await seedRow(id: "F.md", layer: "agent")
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        let doc = MarkdownConverter.shared.parse(after)
        XCTAssertEqual(doc.frontmatter["id"], "ABC")
        XCTAssertEqual(doc.frontmatter["type"], "permanent")
        XCTAssertEqual(doc.frontmatter["status"], "evergreen")
        XCTAssertEqual(MarkdownConverter.shared.frontmatterList(doc, key: "tags"), ["arc"])
        XCTAssertEqual(doc.frontmatter["layer"], "agent")
        XCTAssertTrue(after.hasSuffix(body))
    }

    func testNoFolderMove() async throws {
        defaults.set(true, forKey: enabledKey)
        let url = try writeBlock("G.md", content: "---\ntype: fleeting\n---\n# G\n")
        try await seedRow(id: "G.md", layer: "shared")
        await run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testIdempotent() async throws {
        defaults.set(true, forKey: enabledKey)
        let url = try writeBlock("H.md", content: "---\ntype: fleeting\n---\n# H\n")
        try await seedRow(id: "H.md", layer: "agent")
        let migration = Phase1LayerBackfillMigration(userDefaults: defaults)
        await migration.runIfEnabled(fileService: fileService, database: database, recordWrite: { _ in })
        let before = try String(contentsOf: url, encoding: .utf8)
        await migration.runIfEnabled(fileService: fileService, database: database, recordWrite: { _ in })
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, before, "Second run gated by doneKey")
    }
}
