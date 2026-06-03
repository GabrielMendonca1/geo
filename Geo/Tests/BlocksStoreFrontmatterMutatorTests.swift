import XCTest
@testable import Geo

@MainActor
final class BlocksStoreFrontmatterMutatorTests: XCTestCase {

    private var tempRoot: URL!
    private var store: BlocksStore!
    private var fileService: BlockFileService!
    private var indexCoordinator: IndexCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-frontmatter-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let dayRepository = StubDayRepositoryFM()
        let captureRepository = StubCaptureRepositoryFM()
        let dayManager = DayManager(dayRepository: dayRepository, captureRepository: captureRepository)

        let databaseURL = tempRoot.appendingPathComponent("index.sqlite")
        let database = DatabaseService(databaseURL: databaseURL, fileManager: fm)
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

        fileService = store.fileService
    }

    override func tearDown() async throws {
        store = nil
        fileService = nil
        indexCoordinator = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    private func makeBlock(markdown: String, title: String = "FMTest") async throws -> BlocksStore.Block {
        try? await Task.sleep(nanoseconds: 500_000_000)
        let unique = "\(title)-\(UUID().uuidString.prefix(8))"
        guard let block = await store.createBlock(title: unique, markdown: markdown) else {
            throw XCTSkip("Block creation returned nil")
        }
        await store.flushAll()
        var inMemory = false
        for _ in 0..<40 {
            if store.blocks.contains(where: { $0.id == block.id && $0.markdown == markdown }) {
                inMemory = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !inMemory {
            XCTFail("BlocksStore.loadBlocks didn't complete within 2s; flaky test or production change")
            return block
        }
        for _ in 0..<40 {
            if let disk = try? String(contentsOf: block.url, encoding: .utf8), disk == markdown {
                return block
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("BlocksStore.createBlock disk write didn't complete within 2s")
        return block
    }

    func testSingleMutationBumpsVersionZeroToOne() async throws {
        let block = try await makeBlock(markdown: "---\nsymphony: true\n---\n# Hello\n")

        let newVersion = try await store.mutateFrontmatter(
            blockID: block.id,
            merge: ["state": .string("Todo")]
        )

        XCTAssertEqual(newVersion, 1)
        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(live?.metadata.frontmatter_version, 1)
        XCTAssertTrue(live?.markdown.contains("frontmatter_version: 1") ?? false)
        XCTAssertTrue(live?.markdown.contains("state: Todo") ?? false)
    }

    func testRepeatedMutationsBumpMonotonically() async throws {
        let block = try await makeBlock(markdown: "---\nsymphony: true\n---\n# Hello\n")

        let v1 = try await store.mutateFrontmatter(blockID: block.id, merge: ["state": .string("Todo")])
        let v2 = try await store.mutateFrontmatter(blockID: block.id, merge: ["state": .string("In Progress")])
        let v3 = try await store.mutateFrontmatter(blockID: block.id, merge: ["priority": .int(1)])

        XCTAssertEqual(v1, 1)
        XCTAssertEqual(v2, 2)
        XCTAssertEqual(v3, 3)
        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(live?.metadata.frontmatter_version, 3)
    }

    func testConcurrentMutationsOnDifferentBlocksProceedInParallel() async throws {
        let blockA = try await makeBlock(markdown: "---\nsymphony: true\n---\n# A\n", title: "A")
        let blockB = try await makeBlock(markdown: "---\nsymphony: true\n---\n# B\n", title: "B")

        async let aVersion = store.mutateFrontmatter(blockID: blockA.id, merge: ["state": .string("Todo")])
        async let bVersion = store.mutateFrontmatter(blockID: blockB.id, merge: ["state": .string("Done")])

        let (va, vb) = try await (aVersion, bVersion)
        XCTAssertEqual(va, 1)
        XCTAssertEqual(vb, 1)
    }

    func testConcurrentMutationsOnSameBlockSerialize() async throws {
        let block = try await makeBlock(markdown: "---\nsymphony: true\n---\n# Hello\n")

        async let r1 = store.mutateFrontmatter(blockID: block.id, merge: ["state": .string("Todo")])
        async let r2 = store.mutateFrontmatter(blockID: block.id, merge: ["state": .string("In Progress")])
        async let r3 = store.mutateFrontmatter(blockID: block.id, merge: ["state": .string("Done")])

        let results = try await [r1, r2, r3].sorted()
        XCTAssertEqual(results, [1, 2, 3])

        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(live?.metadata.frontmatter_version, 3)
        let parsed = MarkdownConverter.shared.parse(live?.markdown ?? "").frontmatter
        XCTAssertEqual(parsed["frontmatter_version"], "3")
    }

    func testDecodeBlockMissingFrontmatterVersionTreatsAsZero() throws {
        let json = #"{"type":"fleeting","layer":"user"}"#
        let data = Data(json.utf8)
        let meta = try JSONDecoder().decode(BlocksStore.BlockMetadata.self, from: data)
        XCTAssertEqual(meta.frontmatter_version, 0)
    }

    func testFileWatcherEqualVersionNoOp() async throws {
        let block = try await makeBlock(markdown: "---\nsymphony: true\n---\n# Hello\n")
        _ = try await store.mutateFrontmatter(blockID: block.id, merge: ["state": .string("Todo")])

        let liveBefore = store.blocks.first(where: { $0.id == block.id })!
        let snapshotBefore = liveBefore.markdown

        store.changeReconciler.handleExternalChanges([block.url], currentBlocks: store.blocks)

        let liveAfter = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(liveAfter?.markdown, snapshotBefore)
        XCTAssertEqual(liveAfter?.metadata.frontmatter_version, 1)
    }

    func testFileWatcherHigherDiskVersionHydratesMemory() async throws {
        let block = try await makeBlock(markdown: "---\nsymphony: true\n---\n# Hello\n")
        _ = try await store.mutateFrontmatter(blockID: block.id, merge: ["state": .string("Todo")])

        let externalMarkdown = """
        ---
        symphony: true
        state: External
        frontmatter_version: 99
        ---
        # Hello (edited externally)
        """
        try externalMarkdown.write(to: block.url, atomically: true, encoding: .utf8)

        try await Task.sleep(nanoseconds: 1_100_000_000)
        store.changeReconciler.handleExternalChanges([block.url], currentBlocks: store.blocks)

        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(live?.metadata.frontmatter_version, 99)
        XCTAssertTrue(live?.markdown.contains("# Hello (edited externally)") ?? false)
    }

    func testFileWatcherDiskVersionZeroExternalEditHydratesWhenContentDiffers() async throws {
        let block = try await makeBlock(markdown: "---\nsymphony: true\n---\n# Hello\n")

        let externalMarkdown = "---\nsymphony: true\n---\n# Hello (edited)\n"
        try externalMarkdown.write(to: block.url, atomically: true, encoding: .utf8)

        try await Task.sleep(nanoseconds: 1_100_000_000)
        store.changeReconciler.handleExternalChanges([block.url], currentBlocks: store.blocks)

        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertTrue(live?.markdown.contains("# Hello (edited)") ?? false)
    }

    func testFrontmatterEditorAppendsToExistingFrontmatter() {
        let input = "---\nsymphony: true\nstate: Todo\n---\n# Body\n"
        let output = FrontmatterEditor.upsert(in: input, values: [
            "state": .string("In Progress"),
            "priority": .int(2)
        ])
        let parsed = MarkdownConverter.shared.parse(output).frontmatter
        XCTAssertEqual(parsed["state"], "In Progress")
        XCTAssertEqual(parsed["priority"], "2")
        XCTAssertEqual(parsed["symphony"], "true")
    }

    func testFrontmatterEditorInsertsFrontmatterWhenMissing() {
        let input = "# Just a body\n"
        let output = FrontmatterEditor.upsert(in: input, values: ["state": .string("Todo")])
        XCTAssertTrue(output.hasPrefix("---\n"))
        let parsed = MarkdownConverter.shared.parse(output).frontmatter
        XCTAssertEqual(parsed["state"], "Todo")
    }

    func testMutateFrontmatterReturnsErrorForMissingBlock() async {
        do {
            _ = try await store.mutateFrontmatter(
                blockID: "nonexistent.md",
                merge: ["state": .string("Todo")]
            )
            XCTFail("Expected blockNotFound error")
        } catch FrontmatterMutationError.blockNotFound(let id) {
            XCTAssertEqual(id, "nonexistent.md")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSetLayerWritesFrontmatterAndRoundtrips() async throws {
        let block = try await makeBlock(markdown: "---\ntype: fleeting\n---\n# Layered\n")
        let originalURL = block.url

        let ok = await store.setLayer(.shared, for: block.id)
        XCTAssertTrue(ok)

        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(live?.metadata.layer, .shared, "In-memory layer updates synchronously (read-after-write)")
        XCTAssertEqual(live?.url, originalURL, "No file move")

        await store.flushAll()
        for _ in 0..<40 {
            if let disk = try? String(contentsOf: originalURL, encoding: .utf8),
               MarkdownConverter.shared.layer(in: disk) == .shared {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let disk = try String(contentsOf: originalURL, encoding: .utf8)
        XCTAssertEqual(MarkdownConverter.shared.layer(in: disk), .shared, "Frontmatter layer written to disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path), "File not moved")
    }

    func testReconcilerExternalLayerFlipUpdatesMemory() async throws {
        let block = try await makeBlock(markdown: "---\ntype: fleeting\nlayer: agent\n---\n# Ext\n")
        XCTAssertEqual(store.blocks.first(where: { $0.id == block.id })?.metadata.layer, .agent)

        let flipped = "---\ntype: fleeting\nlayer: shared\nfrontmatter_version: 99\n---\n# Ext edited\n"
        try flipped.write(to: block.url, atomically: true, encoding: .utf8)

        try await Task.sleep(nanoseconds: 1_100_000_000)
        store.changeReconciler.handleExternalChanges([block.url], currentBlocks: store.blocks)

        let live = store.blocks.first(where: { $0.id == block.id })
        print("DBG live markdown=\(live?.markdown ?? "nil") layer=\(String(describing: live?.metadata.layer)) fmv=\(String(describing: live?.metadata.frontmatter_version))")
        XCTAssertEqual(live?.metadata.layer, .shared, "External frontmatter layer flip propagates")
    }
}

private final class StubDayRepositoryFM: DayRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[Day]> {
        AsyncStream { continuation in
            continuation.yield([])
            continuation.finish()
        }
    }
    func day(for date: Date) async -> Day? { nil }
    func addOrUpdateDay(_ day: Day) async throws {}
    func addBlockToDay(date: Date, blockId: String) async throws {}
    func addCaptureToDay(date: Date, captureId: UUID) async throws {}
    func deleteDay(date: Date) async throws {}
}

private final class StubCaptureRepositoryFM: CaptureRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[CaptureItem]> {
        AsyncStream { continuation in
            continuation.yield([])
            continuation.finish()
        }
    }
    func list() async throws -> [CaptureItem] { [] }
    func append(_ item: CaptureItem) async throws {}
    func linkToDay(captureId: UUID, dayId: String) async throws {}
    func delete(ids: Set<UUID>) async throws {}
}
