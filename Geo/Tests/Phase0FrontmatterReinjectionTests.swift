import XCTest
@testable import Geo

final class Phase0FrontmatterReinjectionTests: XCTestCase {

    private var tempRoot: URL!
    private var defaults: UserDefaults!
    private var fileService: BlockFileService!
    private var database: DatabaseService!

    private let enabledKey = "geo.migration.phase0.reinjectFrontmatter"
    private let doneKey = "geo.migration.phase0.reinjectFrontmatter.done"

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-phase0-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let suiteName = "phase0-tests-\(UUID().uuidString)"
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

    private func writeBlock(_ name: String, content: String) throws -> URL {
        let url = fileService.blocksDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func seedRow(
        id: String,
        type: String = "fleeting",
        status: String? = nil,
        layer: String = "user",
        tagId: String? = nil,
        isFullWidth: Bool = false
    ) async throws {
        let entry = BlockIndexEntry(
            id: id,
            path: id,
            title: id,
            content: "",
            createdAt: Date(),
            modifiedAt: Date(),
            tagId: tagId,
            dayId: nil,
            openTaskCount: 0,
            completedTaskCount: 0,
            tags: [],
            type: type,
            status: status,
            layer: layer,
            isFullWidth: isFullWidth
        )
        try await database.upsertBlock(entry)
    }

    private func writeTagsJSON(_ tags: [(id: String, name: String)]) throws {
        let arr = tags.map { Tag(id: $0.id, name: $0.name, color: TagColor(red: 0, green: 0, blue: 0)) }
        let data = try JSONEncoder().encode(arr)
        try data.write(to: tempRoot.appendingPathComponent("Geo/tags.json"))
    }

    private func run() async {
        await Phase0FrontmatterReinjectionMigration(userDefaults: defaults).runIfEnabled(
            fileService: fileService,
            database: database,
            recordWrite: { _ in }
        )
    }

    func testDefaultOffWritesNothing() async throws {
        let url = try writeBlock("A.md", content: "# Title\n\nBody.\n")
        try await seedRow(id: "A.md", layer: "agent")
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "# Title\n\nBody.\n")
        XCTAssertFalse(defaults.bool(forKey: doneKey))
    }

    func testEnabledHappyPath() async throws {
        defaults.set(true, forKey: enabledKey)
        let body = "# Title\n\nBody paragraph.\n"
        let url = try writeBlock("B.md", content: body)
        try await seedRow(id: "B.md", type: "permanent", status: "evergreen", layer: "agent", tagId: "T1", isFullWidth: true)
        try writeTagsJSON([(id: "T1", name: "arc")])
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        let doc = MarkdownConverter.shared.parse(after)
        XCTAssertNotNil(doc.frontmatter["id"])
        XCTAssertFalse(doc.frontmatter["id"]!.isEmpty)
        XCTAssertEqual(doc.frontmatter["type"], "permanent")
        XCTAssertEqual(doc.frontmatter["status"], "evergreen")
        XCTAssertEqual(doc.frontmatter["layer"], "agent")
        XCTAssertEqual(MarkdownConverter.shared.frontmatterList(doc, key: "tags"), ["arc"])
        XCTAssertEqual(doc.frontmatter["full_width"], "true")
        XCTAssertTrue(after.hasSuffix(body))
        XCTAssertTrue(defaults.bool(forKey: doneKey))
    }

    func testStrippedBlockRecovery() async throws {
        defaults.set(true, forKey: enabledKey)
        let url = try writeBlock("C.md", content: "# Stripped\n\nNo frontmatter here.\n")
        try await seedRow(id: "C.md", type: "literature", status: "active", layer: "review")
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        let doc = MarkdownConverter.shared.parse(after)
        XCTAssertEqual(doc.frontmatter["type"], "literature")
        XCTAssertEqual(doc.frontmatter["status"], "active")
        XCTAssertEqual(doc.frontmatter["layer"], "review")
        XCTAssertTrue(after.contains("# Stripped"))
    }

    func testBodyByteIdenticalWithHorizontalRule() async throws {
        defaults.set(true, forKey: enabledKey)
        let body = "\n# Heading\n\nText before rule.\n\n---\n\nText after rule.\n"
        let original = "---\ntype: fleeting\n---\n" + body
        let url = try writeBlock("D.md", content: original)
        try await seedRow(id: "D.md", type: "fleeting", layer: "user")
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(after.hasSuffix(body), "Body (incl. inner --- rule and newlines) must be byte-identical")
    }

    func testFullWidthOmittedWhenFalse() async throws {
        defaults.set(true, forKey: enabledKey)
        let url = try writeBlock("E.md", content: "# E\n")
        try await seedRow(id: "E.md", isFullWidth: false)
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(after.contains("full_width"))
    }

    func testIdempotentId() async throws {
        defaults.set(true, forKey: enabledKey)
        let existingId = "11111111-2222-3333-4444-555555555555"
        let url = try writeBlock("F.md", content: "---\nid: \(existingId)\ntype: fleeting\n---\n# F\n")
        try await seedRow(id: "F.md", type: "permanent", layer: "agent")
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        let doc = MarkdownConverter.shared.parse(after)
        XCTAssertEqual(doc.frontmatter["id"], existingId)
        XCTAssertEqual(doc.frontmatter["type"], "permanent")

        let before = after
        await run()
        let afterSecond = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(afterSecond, before, "Second run is a no-op (doneKey gates it)")
    }

    func testAbortOnEmptyDatabase() async throws {
        defaults.set(true, forKey: enabledKey)
        let original = "# Untouched\n"
        let url = try writeBlock("G.md", content: original)
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, original)
        XCTAssertFalse(defaults.bool(forKey: doneKey))
    }

    func testLayerWrittenAsPropertyNoFolderMove() async throws {
        defaults.set(true, forKey: enabledKey)
        let url = try writeBlock("H.md", content: "# H\n")
        try await seedRow(id: "H.md", layer: "review")
        await run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "File must NOT be moved between folders")
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(MarkdownConverter.shared.parse(after).frontmatter["layer"], "review")
    }

    func testUnresolvedTagIdOmitted() async throws {
        defaults.set(true, forKey: enabledKey)
        let url = try writeBlock("I.md", content: "# I\n")
        try await seedRow(id: "I.md", tagId: "UNKNOWN")
        try writeTagsJSON([(id: "T1", name: "arc")])
        await run()
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(after.contains("tags:"), "Unresolved tagId must not pollute the tag namespace")
    }
}
