import XCTest
@testable import Geo

@MainActor
final class Phase3DayStoreDeriveTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-phase3-derive-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        try await super.tearDown()
    }

    private func entry(_ id: String, dayIds: [String]) -> BlockIndexEntry {
        BlockIndexEntry(
            id: id, path: id, title: id, content: "",
            createdAt: Date(), modifiedAt: Date(),
            tagId: nil, dayId: nil, openTaskCount: 0, completedTaskCount: 0,
            tags: [], type: "fleeting", status: nil, layer: "agent",
            isFullWidth: false, dayIds: dayIds
        )
    }

    func testDeriveSafeFlipUnionsBlockDaysWithCacheAndKeepsCaptures() async throws {
        let database = DatabaseService(databaseURL: tempRoot.appendingPathComponent("index.sqlite"), fileManager: FileManager.default)
        try await database.upsertBlock(entry("A.md", dayIds: ["2026-06-01"]))
        try await database.upsertBlock(entry("B.md", dayIds: ["2026-06-01"]))
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
        for _ in 0..<60 {
            if let day = store.day(for: "2026-06-01"), day.blockIds.count >= 3 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let day = store.day(for: "2026-06-01")
        XCTAssertNotNil(day, "Day struct + @Published days preserved")
        let ids = Set(day?.blockIds ?? [])
        XCTAssertTrue(ids.contains("A.md"), "derived block present")
        XCTAssertTrue(ids.contains("B.md"), "derived block present")
        XCTAssertTrue(ids.contains("C.md"), "safe flip: un-inlined cache block not dropped")
        XCTAssertEqual(day?.captureIds.count, 1, "captures retained via cache")
    }
}
