import XCTest
@testable import Geo

@MainActor
final class SidecarRetirementTests: XCTestCase {

    private var tempRoot: URL!
    private var store: BlocksStore!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-sidecar-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let dayManager = DayManager(dayRepository: StubDayRepositorySC(), captureRepository: StubCaptureRepositorySC())
        let database = DatabaseService(databaseURL: tempRoot.appendingPathComponent("index.sqlite"), fileManager: fm)
        let indexCoordinator = IndexCoordinator(database: database, indexer: MarkdownIndexingService())
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
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        try await super.tearDown()
    }

    func testReconcilerIgnoresSidecarChangeEvent() async throws {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let block = await store.createBlock(title: "SC-\(UUID().uuidString.prefix(6))", markdown: "---\ntype: fleeting\n---\n# Body\n") else {
            throw XCTSkip("Block creation returned nil")
        }
        await store.flushAll()
        for _ in 0..<40 {
            if store.blocks.contains(where: { $0.id == block.id }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        var notified = false
        let token = NotificationCenter.default.addObserver(forName: .blocksExternallyChanged, object: nil, queue: nil) { _ in
            notified = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let sidecarURL = store.fileService.blocksDirectory.appendingPathComponent(".blocks-metadata.json")
        store.changeReconciler.handleExternalChanges([sidecarURL], currentBlocks: store.blocks)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(notified, "Sidecar change events must be ignored after Phase 4 retirement")
    }

    func testReconcilerStillReactsToRealMarkdownEdit() async throws {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let block = await store.createBlock(title: "SC-\(UUID().uuidString.prefix(6))", markdown: "---\ntype: fleeting\n---\n# Body\n") else {
            throw XCTSkip("Block creation returned nil")
        }
        await store.flushAll()
        for _ in 0..<40 {
            if store.blocks.contains(where: { $0.id == block.id }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        var changedIds: [String] = []
        let token = NotificationCenter.default.addObserver(forName: .blocksExternallyChanged, object: nil, queue: nil) { note in
            if let ids = note.userInfo?[BlockExternalChangeKey.changedIds] as? [String] { changedIds.append(contentsOf: ids) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let edited = "---\ntype: permanent\nfrontmatter_version: 99\n---\n# Body edited externally\n"
        try edited.write(to: block.url, atomically: true, encoding: .utf8)
        // Wait past the reconciler's own-write grace period so the edit is treated as external.
        try await Task.sleep(nanoseconds: 1_600_000_000)

        store.changeReconciler.handleExternalChanges([block.url], currentBlocks: store.blocks)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(changedIds.contains(block.id), "Real .md edits must still trigger .blocksExternallyChanged")
        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(live?.metadata.type, .permanent)
    }
}

private final class StubDayRepositorySC: DayRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[Day]> { AsyncStream { $0.yield([]); $0.finish() } }
    func day(for date: Date) async -> Day? { nil }
    func addOrUpdateDay(_ day: Day) async throws {}
    func addBlockToDay(date: Date, blockId: String) async throws {}
    func addCaptureToDay(date: Date, captureId: UUID) async throws {}
    func deleteDay(date: Date) async throws {}
}

private final class StubCaptureRepositorySC: CaptureRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[CaptureItem]> { AsyncStream { $0.yield([]); $0.finish() } }
    func list() async throws -> [CaptureItem] { [] }
    func append(_ item: CaptureItem) async throws {}
    func linkToDay(captureId: UUID, dayId: String) async throws {}
    func delete(ids: Set<UUID>) async throws {}
}
