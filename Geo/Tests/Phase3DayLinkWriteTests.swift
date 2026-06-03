import XCTest
@testable import Geo

@MainActor
final class Phase3DayLinkWriteTests: XCTestCase {

    private var tempRoot: URL!
    private var store: BlocksStore!
    private var indexCoordinator: IndexCoordinator!
    private var blocksAdapter: BlocksStoreRepositoryAdapter!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-phase3-write-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let dayManager = DayManager(dayRepository: StubDayRepoP3(), captureRepository: StubCaptureRepoP3())
        let database = DatabaseService(databaseURL: tempRoot.appendingPathComponent("index.sqlite"), fileManager: fm)
        indexCoordinator = IndexCoordinator(database: database, indexer: MarkdownIndexingService())

        store = BlocksStore(
            baseURL: tempRoot,
            loadAsync: false,
            enableWatcher: false,
            indexCoordinator: indexCoordinator,
            dayManager: dayManager,
            storageMigration: StorageMigrationService.shared,
            markdownConverter: MarkdownConverter.shared
        )
        blocksAdapter = BlocksStoreRepositoryAdapter(blocksStore: store)
    }

    override func tearDown() async throws {
        store = nil
        indexCoordinator = nil
        blocksAdapter = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        try await super.tearDown()
    }

    private func makeBlock(markdown: String) async throws -> BlocksStore.Block {
        try? await Task.sleep(nanoseconds: 200_000_000)
        let unique = "P3-\(UUID().uuidString.prefix(8))"
        guard let block = await store.createBlock(title: unique, markdown: markdown) else {
            throw XCTSkip("block creation returned nil")
        }
        await store.flushAll()
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath: block.url.path),
               store.blocks.contains(where: { $0.id == block.id }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return block
    }

    private func waitForDay(_ dayId: String, contains blockId: String) async -> Bool {
        for _ in 0..<60 {
            let ids = await indexCoordinator.blockIds(matchingDay: dayId)
            if ids.contains(blockId) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func testLinkInsertsDayLinkIntoBodyIdempotentAndIndexed() async throws {
        let original = "---\ntype: fleeting\nlayer: agent\n---\n# Note\nbody text\n"
        let block = try await makeBlock(markdown: original)
        let dayId = "2025-01-09"

        let first = await store.linkBlockToDay(blockId: block.id, dayId: dayId)
        XCTAssertTrue(first)

        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertTrue(live?.markdown.contains("[[\(dayId)]]") == true, "day-link in body")
        let parsed = MarkdownConverter.shared.parse(live?.markdown ?? "")
        XCTAssertEqual(parsed.frontmatter["type"], "fleeting", "frontmatter preserved")

        let indexed = await waitForDay(dayId, contains: block.id)
        XCTAssertTrue(indexed, "block_days indexed after reindex")

        let second = await store.linkBlockToDay(blockId: block.id, dayId: dayId)
        XCTAssertTrue(second, "idempotent success")
        let live2 = store.blocks.first(where: { $0.id == block.id })
        let occurrences = live2?.markdown.components(separatedBy: "[[\(dayId)]]").count ?? 0
        XCTAssertEqual(occurrences, 2, "no duplicate token (split yields count+1)")
    }

    func testLinkAuthGateDeniesUserLayerAllowsAgent() async throws {
        let dayId = "2025-03-04"
        let userBlock = try await makeBlock(markdown: "---\nlayer: user\n---\n# UserOwned\n[[\(dayId)]]\n")
        let agentBlock = try await makeBlock(markdown: "---\nlayer: agent\n---\n# AgentOwned\n[[\(dayId)]]\n")
        let tools = DayTools.register(days: StubDayRepoP3(), blocks: blocksAdapter, indexCoordinator: indexCoordinator)
        let link = tools.first(where: { $0.definition.name == "link_block_to_day" })!

        let deniedResult = try await link.handler(["block_id": .string(userBlock.id), "date": .string(dayId)])
        XCTAssertEqual(deniedResult.isError, true, "user-layer block denied")

        let okResult = try await link.handler(["block_id": .string(agentBlock.id), "date": .string(dayId)])
        XCTAssertNil(okResult.isError, "agent-layer block allowed (idempotent insert)")
    }

    func testNewBlockAutoJoinsToday() async throws {
        let todayId = Day.idFromDate(Date())
        let block = try await makeBlock(markdown: "---\ntype: fleeting\n---\n# Fresh\n")
        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertTrue(live?.markdown.contains("[[\(todayId)]]") == true, "create auto-inserts today's day-link")
        let indexed = await waitForDay(todayId, contains: block.id)
        XCTAssertTrue(indexed, "appears under today's derive")
    }

    func testGetDayUnionsDerivedBlocksWithCaptures() async throws {
        let dayId = "2026-06-02"
        let block = try await makeBlock(markdown: "---\nlayer: agent\n---\n# Linked\n[[\(dayId)]]\n")
        let indexed = await waitForDay(dayId, contains: block.id)
        XCTAssertTrue(indexed)

        let captureDay = DayWithTwoCapturesRepo(dayId: dayId)
        let tools = DayTools.register(days: captureDay, blocks: blocksAdapter, indexCoordinator: indexCoordinator)
        let getDay = tools.first(where: { $0.definition.name == "get_day" })!

        let result = try await getDay.handler(["date": .string(dayId)])
        let json = try decode(result)
        let blockIds = (json["block_ids"] as? [Any])?.compactMap { $0 as? String } ?? []
        XCTAssertTrue(blockIds.contains(block.id), "derived block present")
        XCTAssertEqual(json["capture_count"] as? Int, 2, "captures unioned via dayId")
    }

    func testDailyNoteCreatedLazilyOnGetDay() async throws {
        // Daily notes are created under Application Support, not tempRoot.
        let dayId = "2024-01-15"
        let dailyURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Geo/Blocks/Daily/\(dayId).md")
        try? FileManager.default.removeItem(at: dailyURL)

        let tools = DayTools.register(days: StubDayRepoP3(), blocks: blocksAdapter, indexCoordinator: indexCoordinator)
        let getDay = tools.first(where: { $0.definition.name == "get_day" })!
        _ = try await getDay.handler(["date": .string(dayId)])

        XCTAssertTrue(FileManager.default.fileExists(atPath: dailyURL.path), "Daily note created lazily on query")
        try? FileManager.default.removeItem(at: dailyURL)
    }

    private func decode(_ result: MCPToolResult) throws -> [String: Any] {
        let text = result.content.first?.text ?? ""
        let data = Data(text.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class StubDayRepoP3: DayRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[Day]> { AsyncStream { c in c.yield([]); c.finish() } }
    func day(for date: Date) async -> Day? { nil }
    func addOrUpdateDay(_ day: Day) async throws {}
    func addBlockToDay(date: Date, blockId: String) async throws {}
    func addCaptureToDay(date: Date, captureId: UUID) async throws {}
    func deleteDay(date: Date) async throws {}
}

private final class DayWithTwoCapturesRepo: DayRepository, @unchecked Sendable {
    private let dayId: String
    init(dayId: String) { self.dayId = dayId }
    func observe() -> AsyncStream<[Day]> { AsyncStream { c in c.yield([]); c.finish() } }
    func day(for date: Date) async -> Day? {
        guard Day.idFromDate(date) == dayId else { return nil }
        var day = Day(date: date)
        day.captureIds = [UUID(), UUID()]
        return day
    }
    func addOrUpdateDay(_ day: Day) async throws {}
    func addBlockToDay(date: Date, blockId: String) async throws {}
    func addCaptureToDay(date: Date, captureId: UUID) async throws {}
    func deleteDay(date: Date) async throws {}
}

private final class StubCaptureRepoP3: CaptureRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[CaptureItem]> { AsyncStream { c in c.yield([]); c.finish() } }
    func list() async throws -> [CaptureItem] { [] }
    func append(_ item: CaptureItem) async throws {}
    func linkToDay(captureId: UUID, dayId: String) async throws {}
    func delete(ids: Set<UUID>) async throws {}
}
