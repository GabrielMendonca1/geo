import XCTest
@testable import Geo

@MainActor
final class Phase2TagWriteTests: XCTestCase {

    private var tempRoot: URL!
    private var store: BlocksStore!
    private var indexCoordinator: IndexCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-phase2-write-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let dayManager = DayManager(dayRepository: StubDayRepoP2(), captureRepository: StubCaptureRepoP2())
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
    }

    override func tearDown() async throws {
        store = nil
        indexCoordinator = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        try await super.tearDown()
    }

    private func makeBlock(markdown: String) async throws -> BlocksStore.Block {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let unique = "P2-\(UUID().uuidString.prefix(8))"
        guard let block = await store.createBlock(title: unique, markdown: markdown) else {
            throw XCTSkip("block creation returned nil")
        }
        await store.flushAll()
        for _ in 0..<40 {
            if store.blocks.contains(where: { $0.id == block.id && $0.markdown == markdown }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return block
    }

    func testSetTagByNameWritesSingleElementInlineList() async throws {
        let block = try await makeBlock(markdown: "---\ntype: fleeting\n---\n# Tagged\n")

        let ok = await store.setTagByName("ARC", for: block.id)
        XCTAssertTrue(ok)

        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(live?.metadata.tagName, "arc", "canonical lowercase+NFC name stored in-memory")

        let parsed = MarkdownConverter.shared.parse(live?.markdown ?? "")
        let list = MarkdownConverter.shared.frontmatterList(parsed, key: "tags")
        XCTAssertEqual(list, ["arc"], "exactly one element — single-tag UI invariant")
    }

    func testSetTagByNameClearWritesEmptyList() async throws {
        let block = try await makeBlock(markdown: "---\ntype: fleeting\ntags: [arc]\n---\n# Tagged\n")
        _ = await store.setTagByName("arc", for: block.id)

        let ok = await store.setTagByName(nil, for: block.id)
        XCTAssertTrue(ok)

        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertNil(live?.metadata.tagName)
        let parsed = MarkdownConverter.shared.parse(live?.markdown ?? "")
        XCTAssertEqual(MarkdownConverter.shared.frontmatterList(parsed, key: "tags"), [])
    }

    func testSetTagByNameRoundtripsThroughDiskAndIndex() async throws {
        let block = try await makeBlock(markdown: "---\ntype: fleeting\n---\n# Disk\n")
        _ = await store.setTagByName("Work", for: block.id)
        await store.flushAll()

        for _ in 0..<40 {
            if let disk = try? String(contentsOf: block.url, encoding: .utf8),
               MarkdownConverter.shared.frontmatterList(MarkdownConverter.shared.parse(disk), key: "tags") == ["work"] {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let disk = try String(contentsOf: block.url, encoding: .utf8)
        XCTAssertEqual(MarkdownConverter.shared.frontmatterList(MarkdownConverter.shared.parse(disk), key: "tags"), ["work"])

        let ids = await indexCoordinator.blockIds(matchingTag: "work")
        XCTAssertTrue(ids.contains(block.id), "block_tags cache derives the name (lowercased)")
    }

    func testSetTagCanonicalizesAccentedName() async throws {
        let block = try await makeBlock(markdown: "---\ntype: fleeting\n---\n# Accent\n")
        let nfd = "Introduc\u{0327}a\u{0303}o"
        _ = await store.setTagByName(nfd, for: block.id)

        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(live?.metadata.tagName, TagStore.canonicalName("Introdução"))
    }
}

private final class StubDayRepoP2: DayRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[Day]> { AsyncStream { c in c.yield([]); c.finish() } }
    func day(for date: Date) async -> Day? { nil }
    func addOrUpdateDay(_ day: Day) async throws {}
    func addBlockToDay(date: Date, blockId: String) async throws {}
    func addCaptureToDay(date: Date, captureId: UUID) async throws {}
    func deleteDay(date: Date) async throws {}
}

private final class StubCaptureRepoP2: CaptureRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[CaptureItem]> { AsyncStream { c in c.yield([]); c.finish() } }
    func list() async throws -> [CaptureItem] { [] }
    func append(_ item: CaptureItem) async throws {}
    func linkToDay(captureId: UUID, dayId: String) async throws {}
    func delete(ids: Set<UUID>) async throws {}
}
