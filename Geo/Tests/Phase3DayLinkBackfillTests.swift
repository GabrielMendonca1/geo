import XCTest
@testable import Geo

final class Phase3DayLinkBackfillTests: XCTestCase {

    private var tempRoot: URL!
    private var defaults: UserDefaults!
    private var fileService: BlockFileService!

    private let enabledKey = "geo.migration.phase3.backfillDayLinks"
    private let doneKey = "geo.migration.phase3.backfillDayLinks.done"

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-phase3-backfill-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "phase3-tests-\(UUID().uuidString)")!
        fileService = BlockFileService(baseURL: tempRoot)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        defaults = nil
        fileService = nil
        try await super.tearDown()
    }

    @discardableResult
    private func writeBlock(_ relativePath: String, content: String) throws -> URL {
        let url = fileService.blocksDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeDaysJSON(_ days: [Day]) throws {
        let supportDir = fileService.blocksDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(days)
        try data.write(to: supportDir.appendingPathComponent("days.json"), options: .atomic)
    }

    private func makeDay(_ dayId: String, blockIds: [String]) -> Day {
        var day = Day(date: DateFormatters.dayId.date(from: dayId)!)
        day.blockIds = blockIds
        return day
    }

    private func run() async {
        await Phase3DayLinkBackfillMigration(userDefaults: defaults).runIfEnabled(
            fileService: fileService,
            recordWrite: { _ in }
        )
    }

    func testDefaultOffWritesNothing() async throws {
        let url = try writeBlock("Note.md", content: "# Note\n")
        try writeDaysJSON([makeDay("2026-06-01", blockIds: ["Note.md"])])

        await run()

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("[["), "no day-link injected when default off")
        XCTAssertFalse(defaults.bool(forKey: doneKey), "done not set")
    }

    func testEmptyInputAbortDoesNotMarkDone() async throws {
        defaults.set(true, forKey: enabledKey)
        // No days.json written.
        await run()
        XCTAssertFalse(defaults.bool(forKey: doneKey), "abort without marking done so it re-runs")
    }

    func testBareFilenameResolvesToRelativeIdAndInjects() async throws {
        defaults.set(true, forKey: enabledKey)
        let url = try writeBlock("Semanas/Semana-8.md", content: "# Semana 8\n")
        try writeDaysJSON([makeDay("2026-06-01", blockIds: ["Semana-8.md"])])

        await run()

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("[[2026-06-01]]"), "subfolder block resolved via basename map and injected")
        XCTAssertTrue(defaults.bool(forKey: doneKey))

        let dailyURL = fileService.blocksDirectory.appendingPathComponent("Daily/2026-06-01.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dailyURL.path), "daily note created for migrated day")
    }

    func testAmbiguousBasenameDropped() async throws {
        defaults.set(true, forKey: enabledKey)
        let a = try writeBlock("FolderA/Index.md", content: "# A\n")
        let b = try writeBlock("FolderB/Index.md", content: "# B\n")
        try writeDaysJSON([makeDay("2026-06-01", blockIds: ["Index.md"])])

        await run()

        let contentA = try String(contentsOf: a, encoding: .utf8)
        let contentB = try String(contentsOf: b, encoding: .utf8)
        XCTAssertFalse(contentA.contains("[["), "ambiguous basename dropped, not injected")
        XCTAssertFalse(contentB.contains("[["), "ambiguous basename dropped, not injected")
        XCTAssertTrue(defaults.bool(forKey: doneKey), "migration completes despite drop")
    }

    func testIdempotentSkipsExistingDayLinkAndKeepsDaysJSON() async throws {
        defaults.set(true, forKey: enabledKey)
        let url = try writeBlock("Note.md", content: "# Note\n[[2026-06-01]]\n")
        try writeDaysJSON([makeDay("2026-06-01", blockIds: ["Note.md"])])

        await run()

        let content = try String(contentsOf: url, encoding: .utf8)
        let occurrences = content.components(separatedBy: "[[2026-06-01]]").count
        XCTAssertEqual(occurrences, 2, "no duplicate token (already present skipped)")

        let daysURL = fileService.blocksDirectory.deletingLastPathComponent().appendingPathComponent("days.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: daysURL.path), "days.json retained as cache")
    }
}
