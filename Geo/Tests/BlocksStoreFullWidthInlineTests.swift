import XCTest
@testable import Geo

@MainActor
final class BlocksStoreFullWidthInlineTests: XCTestCase {

    private var tempRoot: URL!
    private var store: BlocksStore!
    private var indexCoordinator: IndexCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-fullwidth-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let dayManager = DayManager(dayRepository: StubDayRepositoryFW(), captureRepository: StubCaptureRepositoryFW())
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

    private func makeBlock() async throws -> BlocksStore.Block {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let unique = "FW-\(UUID().uuidString.prefix(8))"
        guard let block = await store.createBlock(title: unique, markdown: "---\ntype: fleeting\n---\n# Body\n") else {
            throw XCTSkip("Block creation returned nil")
        }
        await store.flushAll()
        for _ in 0..<40 {
            if store.blocks.contains(where: { $0.id == block.id }) { return block }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Block did not appear in store within 2s")
        return block
    }

    private func waitForFullWidth(_ id: String, expected: Bool) async -> Bool {
        for _ in 0..<60 {
            if store.blocks.first(where: { $0.id == id })?.metadata.isFullWidth == expected { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return store.blocks.first(where: { $0.id == id })?.metadata.isFullWidth == expected
    }

    func testSetFullWidthTrueWritesFrontmatter() async throws {
        let block = try await makeBlock()
        store.setFullWidth(true, for: block.id)

        let became = await waitForFullWidth(block.id, expected: true)
        XCTAssertTrue(became)
        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertTrue(live?.metadata.isFullWidth ?? false)
        XCTAssertTrue(MarkdownConverter.shared.fullWidth(in: live?.markdown ?? ""))

        for _ in 0..<40 {
            if let disk = try? String(contentsOf: block.url, encoding: .utf8),
               MarkdownConverter.shared.fullWidth(in: disk) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let disk = try String(contentsOf: block.url, encoding: .utf8)
        XCTAssertTrue(MarkdownConverter.shared.fullWidth(in: disk), "full_width: true written to disk frontmatter")
    }

    func testSetFullWidthFalseOmitsKey() async throws {
        let block = try await makeBlock()
        store.setFullWidth(true, for: block.id)
        let becameTrue = await waitForFullWidth(block.id, expected: true)
        XCTAssertTrue(becameTrue)

        store.setFullWidth(false, for: block.id)
        let becameFalse = await waitForFullWidth(block.id, expected: false)
        XCTAssertTrue(becameFalse)

        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertFalse(live?.metadata.isFullWidth ?? true)
        XCTAssertFalse(MarkdownConverter.shared.fullWidth(in: live?.markdown ?? ""))
    }

    func testLoadDerivesFullWidthFromFrontmatter() async throws {
        let block = try await makeBlock()
        store.setFullWidth(true, for: block.id)
        let became = await waitForFullWidth(block.id, expected: true)
        XCTAssertTrue(became)
        await store.flushAll()

        // Wait for full_width to land on disk before reloading from files.
        for _ in 0..<60 {
            if let disk = try? String(contentsOf: block.url, encoding: .utf8),
               MarkdownConverter.shared.fullWidth(in: disk) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Reload via files: full_width should be derived from frontmatter, not SQLite.
        let metaless: [String: BlocksStore.BlockMetadata] = [:]
        let reloaded = await store.fileService.loadBlocksFromFiles(metadata: metaless, converter: MarkdownConverter.shared)
        let target = reloaded.first(where: { $0.id == block.id })
        XCTAssertNotNil(target)
        XCTAssertTrue(target?.metadata.isFullWidth ?? false, "full_width derived from frontmatter on file load")
    }
}

private final class StubDayRepositoryFW: DayRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[Day]> { AsyncStream { $0.yield([]); $0.finish() } }
    func day(for date: Date) async -> Day? { nil }
    func addOrUpdateDay(_ day: Day) async throws {}
    func addBlockToDay(date: Date, blockId: String) async throws {}
    func addCaptureToDay(date: Date, captureId: UUID) async throws {}
    func deleteDay(date: Date) async throws {}
}

private final class StubCaptureRepositoryFW: CaptureRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[CaptureItem]> { AsyncStream { $0.yield([]); $0.finish() } }
    func list() async throws -> [CaptureItem] { [] }
    func append(_ item: CaptureItem) async throws {}
    func linkToDay(captureId: UUID, dayId: String) async throws {}
    func delete(ids: Set<UUID>) async throws {}
}
