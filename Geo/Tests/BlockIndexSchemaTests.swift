import XCTest
import GRDB
@testable import Geo

final class BlockIndexSchemaTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockIndexSchemaTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("blocks.sqlite")
    }

    override func tearDown() {
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        }
        tempURL = nil
        super.tearDown()
    }

    private func makeService() -> DatabaseService {
        DatabaseService(databaseURL: tempURL)
    }

    private func makeEntry(
        id: String,
        title: String,
        content: String,
        modifiedAt: Date = Date(),
        type: String = "fleeting",
        status: String? = nil,
        layer: String = "user"
    ) -> BlockIndexEntry {
        BlockIndexEntry(
            id: id,
            path: "/tmp/\(id).md",
            title: title,
            content: content,
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            tagId: nil,
            dayId: nil,
            openTaskCount: 0,
            completedTaskCount: 0,
            tags: [],
            type: type,
            status: status,
            layer: layer
        )
    }

    func testMigrationBackfillsTypeAndStatusFromMarkdown() async throws {
        let projectMarkdown = """
        ---
        type: project
        status: Active
        ---
        # Project body
        """
        let permanentMarkdown = """
        ---
        type: permanent
        ---
        # Permanent body
        """
        let plainMarkdown = "# Plain block"

        let now = Date()
        let dbQueue = try DatabaseQueue(path: tempURL.path)
        try await dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE blocks (
                    id TEXT PRIMARY KEY,
                    path TEXT NOT NULL,
                    title TEXT NOT NULL,
                    content TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    modifiedAt DATETIME NOT NULL,
                    tagId TEXT,
                    dayId TEXT,
                    openTaskCount INTEGER NOT NULL DEFAULT 0,
                    completedTaskCount INTEGER NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: """
                CREATE TABLE block_tags (
                    blockId TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (blockId, tag)
                )
            """)
            try db.execute(sql: "CREATE INDEX block_tags_tag ON block_tags(tag)")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE blocks_fts USING fts5(blockId, title, content)
            """)
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                )
            """)
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: ["createBlocks"])
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: ["dropBlocksFrontmatter"])

            for (id, title, content) in [
                ("p1", "Project", projectMarkdown),
                ("p2", "Permanent", permanentMarkdown),
                ("p3", "Plain", plainMarkdown)
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO blocks (id, path, title, content, createdAt, modifiedAt, tagId, dayId, openTaskCount, completedTaskCount)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, 0, 0)
                    """,
                    arguments: [id, "/tmp/\(id).md", title, content, now, now]
                )
            }
        }

        let reopened = DatabaseService(databaseURL: tempURL)
        let all = try await reopened.fetchAllBlocks()
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        XCTAssertEqual(byId["p1"]?.type, "project")
        XCTAssertEqual(byId["p1"]?.status, "active")
        XCTAssertEqual(byId["p2"]?.type, "permanent")
        XCTAssertNil(byId["p2"]?.status)
        XCTAssertEqual(byId["p3"]?.type, "fleeting")
        XCTAssertNil(byId["p3"]?.status)
        XCTAssertEqual(byId["p3"]?.layer, "user")
    }

    func testFetchBlocksByTypeReturnsOnlyMatching() async throws {
        let service = makeService()
        try await service.upsertBlock(makeEntry(id: "a", title: "A", content: "alpha", type: "project"))
        try await service.upsertBlock(makeEntry(id: "b", title: "B", content: "beta", type: "permanent"))
        try await service.upsertBlock(makeEntry(id: "c", title: "C", content: "gamma", type: "project"))

        let projects = try await service.fetchBlocks(byType: "project")
        XCTAssertEqual(Set(projects.map { $0.id }), ["a", "c"])
        let permanents = try await service.fetchBlocks(byType: "permanent")
        XCTAssertEqual(permanents.map { $0.id }, ["b"])
    }

    func testFetchBlocksByStatusReturnsOnlyMatching() async throws {
        let service = makeService()
        try await service.upsertBlock(makeEntry(id: "a", title: "A", content: "alpha", type: "project", status: "active"))
        try await service.upsertBlock(makeEntry(id: "b", title: "B", content: "beta", type: "project", status: "done"))
        try await service.upsertBlock(makeEntry(id: "c", title: "C", content: "gamma", type: "fleeting", status: nil))

        let active = try await service.fetchBlocks(byStatus: "active")
        XCTAssertEqual(active.map { $0.id }, ["a"])
        let done = try await service.fetchBlocks(byStatus: "done")
        XCTAssertEqual(done.map { $0.id }, ["b"])
    }

    func testBlockIdsMatchingTypeAndStatus() async throws {
        let service = makeService()
        let now = Date()
        try await service.upsertBlock(makeEntry(id: "a", title: "A", content: "x", modifiedAt: now.addingTimeInterval(-100), type: "project", status: "active"))
        try await service.upsertBlock(makeEntry(id: "b", title: "B", content: "y", modifiedAt: now, type: "project", status: "active"))
        try await service.upsertBlock(makeEntry(id: "c", title: "C", content: "z", modifiedAt: now.addingTimeInterval(-50), type: "fleeting", status: nil))

        let projectIds = try await service.blockIds(matchingType: "project")
        XCTAssertEqual(projectIds, ["b", "a"])
        let activeIds = try await service.blockIds(matchingStatus: "active")
        XCTAssertEqual(activeIds, ["b", "a"])
    }

    func testSearchBlocksContainingWikiLinkIsCaseInsensitive() async throws {
        let service = makeService()
        try await service.upsertBlock(makeEntry(id: "a", title: "A", content: "see [[Alpha]] for details"))
        try await service.upsertBlock(makeEntry(id: "b", title: "B", content: "no link here"))
        try await service.upsertBlock(makeEntry(id: "c", title: "C", content: "ref [[ALPHA]] uppercase"))

        let lower = try await service.searchBlocksContaining(wikiLink: "alpha")
        XCTAssertEqual(Set(lower.map { $0.id }), ["a", "c"])
        let mixed = try await service.searchBlocksContaining(wikiLink: "Alpha")
        XCTAssertEqual(Set(mixed.map { $0.id }), ["a", "c"])
    }
}
