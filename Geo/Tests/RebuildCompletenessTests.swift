import XCTest
@testable import Geo

/// Guards the CRITICAL INVARIANT of the files-only cutover: a full re-derive from disk must
/// populate block_days/block_tags COMPLETELY from file content in one pass, never leaving the
/// pre-edit (stale) counts that a bulk migration's inline writes would otherwise strand.
@MainActor
final class RebuildCompletenessTests: XCTestCase {

    private var tempRoot: URL!
    private var blocksDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-rebuild-completeness-\(UUID().uuidString)", isDirectory: true)
        blocksDir = tempRoot.appendingPathComponent("Geo/Blocks", isDirectory: true)
        try fm.createDirectory(at: blocksDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        blocksDir = nil
        try await super.tearDown()
    }

    private func writeBlock(_ name: String, _ markdown: String) throws {
        try markdown.write(to: blocksDir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }

    private func countRows(_ db: DatabaseService, table: String) async throws -> Int {
        // Use a known query surface: block_days via blockIds(matchingDay:) summed, block_tags via
        // blockIds(matchingTag:) summed — but simplest is to fetch all entries and count.
        let all = try await db.fetchAllBlocks()
        switch table {
        case "block_days": return all.reduce(0) { $0 + $1.dayIds.count }
        case "block_tags": return all.reduce(0) { $0 + $1.tags.count }
        default: return 0
        }
    }

    func testFullRebuildDerivesBlockDaysAndBlockTagsCompletelyFromFiles() async throws {
        let fm = FileManager.default
        let database = DatabaseService(databaseURL: tempRoot.appendingPathComponent("index.sqlite"), fileManager: fm)
        let coordinator = IndexCoordinator(database: database, indexer: MarkdownIndexingService())
        let fileService = BlockFileService(baseURL: tempRoot)

        // N=6 inline [[date]] links across 3 files; M=4 distinct tags (frontmatter + body).
        try writeBlock("A", "---\ntags: [arc, work]\n---\n# A\n[[2026-06-01]]\n[[2026-06-02]]\n")
        try writeBlock("B", "---\nlayer: agent\n---\n# B\n#bug fix here\n[[2026-06-02]]\n[[2026-06-03]]\n")
        try writeBlock("C", "# C\n#arc again, and #idea\n[[2026-06-03]]\n[[2026-06-04]]\n")

        // Seed the SQLite cache with STALE smaller counts (simulating a bulk migration that
        // inlined the links into files but never re-derived the index).
        try await database.upsertBlock(BlockIndexEntry(
            id: "A.md", path: blocksDir.appendingPathComponent("A.md").path, title: "A", content: "# A\n",
            createdAt: Date(), modifiedAt: Date(), dayId: nil, openTaskCount: 0, completedTaskCount: 0,
            tags: [], type: "fleeting", status: nil, layer: "user", dayIds: ["2026-06-01"]
        ))

        let staleDays = try await countRows(database, table: "block_days")
        let staleTags = try await countRows(database, table: "block_tags")
        XCTAssertEqual(staleDays, 1, "precondition: stale block_days")
        XCTAssertEqual(staleTags, 0, "precondition: stale block_tags")

        // Full re-derive from files.
        let blocks = await fileService.loadBlocksFromFiles(metadata: [:], converter: .shared)
        await coordinator.rebuildIndex(blocks: blocks)

        // Distinct inline [[date]] links: A{06-01,06-02} B{06-02,06-03} C{06-03,06-04}
        // = per-block distinct: A=2, B=2, C=2 -> 6 block_days rows total.
        let derivedDays = try await countRows(database, table: "block_days")
        // Distinct tags: arc, work (A), bug (B), arc, idea (C) -> per-block: A=2, B=1, C=2 = 5 rows.
        let derivedTags = try await countRows(database, table: "block_tags")

        XCTAssertEqual(derivedDays, 6, "block_days == count of inline [[date]] across files, NOT stale 1")
        XCTAssertEqual(derivedTags, 5, "block_tags == frontmatter+body tags across files, NOT stale 0")

        // Spot-check membership queries resolve from block_days.
        let june3 = Set(try await database.blockIds(matchingDay: "2026-06-03"))
        XCTAssertEqual(june3, ["B.md", "C.md"])
        let arc = Set(try await database.blockIds(matchingTag: "arc"))
        XCTAssertEqual(arc, ["A.md", "C.md"])
    }

    func testLayerIsFrontmatterSoleNotSqliteCache() async throws {
        let fm = FileManager.default
        let database = DatabaseService(databaseURL: tempRoot.appendingPathComponent("index.sqlite"), fileManager: fm)
        let coordinator = IndexCoordinator(database: database, indexer: MarkdownIndexingService())

        // File frontmatter says `shared`; seed the SQLite layer CACHE column to a conflicting
        // `agent`. The resolved metadata must follow frontmatter (.shared), never the cache.
        let content = "---\nlayer: shared\n---\n# L\n"
        try await database.upsertBlock(BlockIndexEntry(
            id: "L.md", path: blocksDir.appendingPathComponent("L.md").path, title: "L", content: content,
            createdAt: Date(), modifiedAt: Date(), dayId: nil, openTaskCount: 0, completedTaskCount: 0,
            tags: [], type: "fleeting", status: nil, layer: "agent"
        ))

        let dayManager = DayManager(dayRepository: StubDayRepoRC(), captureRepository: StubCaptureRepoRC())
        let store = BlocksStore(
            baseURL: tempRoot, loadAsync: false, enableWatcher: false,
            indexCoordinator: coordinator, dayManager: dayManager,
            markdownConverter: .shared
        )
        for _ in 0..<60 {
            if store.blocks.contains(where: { $0.id == "L.md" }) { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let block = store.blocks.first(where: { $0.id == "L.md" })
        XCTAssertEqual(block?.metadata.layer, .shared, "layer follows frontmatter, not the stale SQLite cache")
    }

    func testRepairIntegrityReDerivesContentDriftedBlocks() async throws {
        let fm = FileManager.default
        let database = DatabaseService(databaseURL: tempRoot.appendingPathComponent("index.sqlite"), fileManager: fm)
        let coordinator = IndexCoordinator(database: database, indexer: MarkdownIndexingService())
        let fileService = BlockFileService(baseURL: tempRoot)

        // Index a block whose file has NO day-link / tag yet.
        try writeBlock("Drift", "# Drift\nplain body\n")
        let initial = await fileService.loadBlocksFromFiles(metadata: [:], converter: .shared)
        await coordinator.rebuildIndex(blocks: initial)
        let initialDays = try await countRows(database, table: "block_days")
        let initialTags = try await countRows(database, table: "block_tags")
        XCTAssertEqual(initialDays, 0)
        XCTAssertEqual(initialTags, 0)

        // Mutate the FILE out-of-band (not via index(block:)) to add a [[date]] and a #tag.
        try writeBlock("Drift", "---\ntags: [arc]\n---\n# Drift\nplain body #note\n[[2026-06-05]]\n")

        // repairIntegrity must detect the content drift (file != cached blocks.content) and
        // re-upsert the block — re-deriving block_days/block_tags from the new file content.
        await coordinator.repairIntegrity(fileService: fileService, metadata: [:])

        let days = Set(try await database.blockIds(matchingDay: "2026-06-05"))
        XCTAssertEqual(days, ["Drift.md"], "repairIntegrity re-derived block_days from drifted file")
        let noteTag = Set(try await database.blockIds(matchingTag: "note"))
        let arcTag = Set(try await database.blockIds(matchingTag: "arc"))
        XCTAssertEqual(noteTag, ["Drift.md"], "body #tag re-derived")
        XCTAssertEqual(arcTag, ["Drift.md"], "frontmatter tag re-derived")
    }
}

private final class StubDayRepoRC: DayRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[Day]> { AsyncStream { c in c.yield([]); c.finish() } }
    func day(for date: Date) async -> Day? { nil }
}

private final class StubCaptureRepoRC: CaptureRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[CaptureItem]> { AsyncStream { c in c.yield([]); c.finish() } }
    func list() async throws -> [CaptureItem] { [] }
    func append(_ item: CaptureItem) async throws {}
    func linkToDay(captureId: UUID, dayId: String) async throws {}
    func delete(ids: Set<UUID>) async throws {}
}
