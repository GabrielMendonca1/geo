import XCTest
@testable import Geo

@MainActor
final class Phase3DayStoreDeriveTests: XCTestCase {

    private var tempRoot: URL!
    private var indexCoordinator: IndexCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-phase3-derive-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let database = DatabaseService(databaseURL: tempRoot.appendingPathComponent("index.sqlite"), fileManager: fm)
        indexCoordinator = IndexCoordinator(database: database, indexer: MarkdownIndexingService())
    }

    override func tearDown() async throws {
        indexCoordinator = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        try await super.tearDown()
    }

    private func seed(id: String, dayIds: [String]) async throws {
        let entry = BlockIndexEntry(
            id: id, path: id, title: id, content: "",
            createdAt: Date(), modifiedAt: Date(),
            tagId: nil, dayId: nil, openTaskCount: 0, completedTaskCount: 0,
            tags: [], type: "fleeting", status: nil, layer: "agent",
            isFullWidth: false, dayIds: dayIds
        )
        try await (indexCoordinator.value(forKey: "database") as! DatabaseService).upsertBlock(entry)
    }

    func testDeriveSafeFlipUnionsBlockDaysWithCacheAndKeepsCaptures() async throws {
        // Two blocks inlined for the same day via block_days.
        let database = DatabaseService(databaseURL: tempRoot.appendingPathComponent("index.sqlite"), fileManager: FileManager.default)
        let entryA = BlockIndexEntry(id: "A.md", path: "A.md", title: "A", content: "", createdAt: Date(), modifiedAt: Date(), tagId: nil, dayId: nil, openTaskCount: 0, completedTaskCount: 0, tags: [], type: "fleeting", status: nil, layer: "agent", isFullWidth: false, dayIds: ["2026-06-01"])
        let entryB = BlockIndexEntry(id: "B.md", path: "B.md", title: "B", content: "", createdAt: Date(), modifiedAt: Date(), tagId: nil, dayId: nil, openTaskCount: 0, completedTaskCount: 0, tags: [], type: "fleeting", status: nil, layer: "agent", isFullWidth: false, dayIds: ["2026-06-01"])
        try await database.upsertBlock(entryA)
        try await database.upsertBlock(entryB)
        let coordinator = IndexCoordinator(database: database, indexer: MarkdownIndexingService())

        // Seed days.json cache with a NOT-yet-inlined block C (fallback) + a capture.
        let supportDir = tempRoot.appendingPathComponent("Geo")
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        var cachedDay = Day(date: DateFormatters.dayId.date(from: "2026-06-01")!)
        cachedDay.blockIds = ["C.md"]
        cachedDay.captureIds = [UUID()]
        let data = try JSONEncoder().encode([cachedDay])
        try data.write(to: supportDir.appendingPathComponent("days.json"), options: .atomic)

        let store = DayStore(baseURL: tempRoot, indexCoordinator: coordinator)
        // Allow async derive Task to complete.
        for _ in 0..<60 {
            if let day = store.day(for: id: "2026-06-01"), day.blockIds.count >= 3 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let day = store.day(for: id: "2026-06-01")
        XCTAssertNotNil(day, "Day struct + @Published days preserved")
        let ids = Set(day?.blockIds ?? [])
        XCTAssertTrue(ids.contains("A.md"), "derived block present")
        XCTAssertTrue(ids.contains("B.md"), "derived block present")
        XCTAssertTrue(ids.contains("C.md"), "safe flip: un-inlined cache block not dropped")
        XCTAssertEqual(day?.captureIds.count, 1, "captures retained via cache")
    }
}

private extension DayStore {
    func day(for id idArg: String) -> Day? { day(for: idArg) }
}

private extension IndexCoordinator {
    func value(forKey key: String) -> Any? { nil }
}
