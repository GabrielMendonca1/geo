import XCTest
@testable import Geo

@MainActor
final class HermesMigrationFixesTests: XCTestCase {

    private var tempRoot: URL!
    private var store: BlocksStore!
    private var indexCoordinator: IndexCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-hermes-fix-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let dayRepository = StubDayRepoHM()
        let captureRepository = StubCaptureRepoHM()
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
    }

    override func tearDown() async throws {
        store = nil
        indexCoordinator = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    private func makeBlock(markdown: String = "---\nsymphony: true\n---\n# T\n") async throws -> BlocksStore.Block {
        try? await Task.sleep(nanoseconds: 100_000_000)
        let unique = "HM-\(UUID().uuidString.prefix(8))"
        guard let block = await store.createBlock(title: unique, markdown: markdown) else {
            throw XCTSkip("Block creation returned nil")
        }
        await store.flushAll()
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if store.blocks.contains(where: { $0.id == block.id && $0.markdown == markdown }) {
                break
            }
        }
        return block
    }

    func testSetTypeBumpsFrontmatterVersion() async throws {
        let block = try await makeBlock()
        let initialVersion = store.blocks.first(where: { $0.id == block.id })?.metadata.frontmatter_version ?? -1
        let ok = await store.setType(.permanent, for: block.id)
        XCTAssertTrue(ok)
        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(live?.metadata.frontmatter_version, initialVersion + 1)
        XCTAssertEqual(live?.metadata.type, .permanent)
        XCTAssertTrue(live?.markdown.contains("type: permanent") ?? false)
        XCTAssertTrue(live?.markdown.contains("frontmatter_version: \(initialVersion + 1)") ?? false)
    }

    func testSetStatusBumpsFrontmatterVersion() async throws {
        let block = try await makeBlock()
        let initialVersion = store.blocks.first(where: { $0.id == block.id })?.metadata.frontmatter_version ?? -1
        let ok = await store.setStatus("evergreen", for: block.id)
        XCTAssertTrue(ok)
        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(live?.metadata.frontmatter_version, initialVersion + 1)
        XCTAssertEqual(live?.metadata.status, "evergreen")
        XCTAssertTrue(live?.markdown.contains("status: evergreen") ?? false)
    }

    func testSetTypeAndSetStatusBumpMonotonically() async throws {
        let block = try await makeBlock()
        let v0 = store.blocks.first(where: { $0.id == block.id })!.metadata.frontmatter_version
        _ = await store.setType(.project, for: block.id)
        let v1 = store.blocks.first(where: { $0.id == block.id })!.metadata.frontmatter_version
        _ = await store.setStatus("active", for: block.id)
        let v2 = store.blocks.first(where: { $0.id == block.id })!.metadata.frontmatter_version
        XCTAssertEqual(v1, v0 + 1)
        XCTAssertEqual(v2, v1 + 1)
    }

    func testUpdateBlockMCPHandlerStripsAgentFrontmatterVersion() async throws {
        let block = try await makeBlock(markdown: "---\nsymphony: true\nstate: Todo\n---\n# Initial\n")
        _ = await store.setLayer(.shared, for: block.id)
        await store.flushAll()

        _ = try await store.mutateFrontmatter(blockID: block.id, merge: ["state": .string("In Progress")])
        let beforeVersion = store.blocks.first(where: { $0.id == block.id })!.metadata.frontmatter_version
        XCTAssertGreaterThanOrEqual(beforeVersion, 1)

        let repo = BlocksStoreRepositoryAdapter(blocksStore: store)
        let tools = registeredTools(repo: repo)
        guard let updateTool = tools.first(where: { $0.definition.name == "update_block" }) else {
            XCTFail("update_block tool missing")
            return
        }

        let attackerMarkdown = """
        ---
        symphony: true
        state: Stomped
        frontmatter_version: 9999
        ---
        # Stomped body
        """
        let result = try await updateTool.handler([
            "id": .string(block.id),
            "content": .string(attackerMarkdown)
        ])
        XCTAssertEqual(result.isError ?? false, false)
        await store.flushAll()

        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertNotNil(live)
        XCTAssertEqual(live?.metadata.frontmatter_version, beforeVersion + 1)
        XCTAssertFalse(live?.markdown.contains("frontmatter_version: 9999") ?? true)
        XCTAssertTrue(live?.markdown.contains("state: Stomped") ?? false)
        XCTAssertTrue(live?.markdown.contains("# Stomped body") ?? false)
    }

    func testUpdateBlockMCPHandlerBodyOnlyDoesNotBumpVersion() async throws {
        let block = try await makeBlock(markdown: "---\nsymphony: true\nstate: Todo\n---\n# Initial\n")
        _ = await store.setLayer(.shared, for: block.id)
        await store.flushAll()

        _ = try await store.mutateFrontmatter(blockID: block.id, merge: ["state": .string("Todo")])
        let beforeVersion = store.blocks.first(where: { $0.id == block.id })!.metadata.frontmatter_version
        let currentMarkdown = store.blocks.first(where: { $0.id == block.id })!.markdown
        let currentDoc = MarkdownConverter.shared.parse(currentMarkdown)
        let fmKeys = currentDoc.frontmatter.keys.sorted()
        var fmBlock = "---\n"
        for k in fmKeys { fmBlock += "\(k): \(currentDoc.frontmatter[k] ?? "")\n" }
        fmBlock += "---\n"
        let newContent = fmBlock + "# Body only edit\nNew content here.\n"

        let repo = BlocksStoreRepositoryAdapter(blocksStore: store)
        let tools = registeredTools(repo: repo)
        let updateTool = tools.first(where: { $0.definition.name == "update_block" })!

        let result = try await updateTool.handler([
            "id": .string(block.id),
            "content": .string(newContent)
        ])
        XCTAssertEqual(result.isError ?? false, false)
        await store.flushAll()
        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertEqual(live?.metadata.frontmatter_version, beforeVersion)
        XCTAssertTrue(live?.markdown.contains("Body only edit") ?? false)
    }

    func testHandleHermesPartialIgnoresIdFallbackForSessionEvents() {
        let obj: [String: AnyCodableValue] = [
            "type": .string("session"),
            "id": .string("hermes-internal-dispatch-id")
        ]
        let value: AnyCodableValue = .object(obj)
        let extracted = extractPiSessionIdMimic(from: value)
        XCTAssertNil(extracted)

        let obj2: [String: AnyCodableValue] = [
            "type": .string("session"),
            "pi_session_id": .string("019300de-feed-7000-aaaa-bbbbccccdddd")
        ]
        let value2: AnyCodableValue = .object(obj2)
        let extracted2 = extractPiSessionIdMimic(from: value2)
        XCTAssertEqual(extracted2, "019300de-feed-7000-aaaa-bbbbccccdddd")
    }

    private func extractPiSessionIdMimic(from value: AnyCodableValue) -> String? {
        guard case .object(let obj) = value else { return nil }
        let eventType: String? = {
            if case .string(let s)? = obj["type"] { return s }
            if case .string(let s)? = obj["event"] { return s }
            return nil
        }()
        guard eventType == "session" || eventType == "pi_session" else { return nil }
        if case .string(let s)? = obj["pi_session_id"] { return s }
        return nil
    }

    func testAppendReportToIssueNodeCoherentSingleBlock() async throws {
        let initialMarkdown = """
        ---
        symphony: true
        symphony_session_id: existing-session
        state: Todo
        ---
        # Issue Title

        Body description here.

        ## Acceptance
        - thing
        """
        let block = try await makeBlock(markdown: initialMarkdown)
        _ = await store.setLayer(.shared, for: block.id)
        await store.flushAll()

        let repo = BlocksStoreRepositoryAdapter(blocksStore: store)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        _ = try await repo.mutateFrontmatter(blockId: block.id, merge: [
            "state": .string("In Progress"),
            "updated_at": .string(timestamp),
            "symphony": .bool(true)
        ])
        guard let refreshed = try await repo.list().first(where: { $0.id == block.id }) else {
            XCTFail("Block not found after mutate")
            return
        }
        let versionAfterMutate = refreshed.metadata.frontmatter_version
        let bodyWithReport = refreshed.markdown + "\n\n## Agent Report - pi - \(timestamp)\nReport text body."
        try await repo.update(id: block.id, markdown: bodyWithReport)
        await store.flushAll()

        let live = store.blocks.first(where: { $0.id == block.id })
        XCTAssertNotNil(live)
        XCTAssertEqual(live?.metadata.frontmatter_version, versionAfterMutate)
        let fm = MarkdownConverter.shared.parse(live?.markdown ?? "").frontmatter
        XCTAssertEqual(fm["state"], "In Progress")
        XCTAssertEqual(fm["frontmatter_version"], String(versionAfterMutate))
        XCTAssertTrue(live?.markdown.contains("Body description here.") ?? false)
        XCTAssertTrue(live?.markdown.contains("Report text body.") ?? false)
        let frontmatterDelimiterCount = live?.markdown.components(separatedBy: "\n---\n").count ?? 0
        XCTAssertLessThanOrEqual(frontmatterDelimiterCount, 2)
    }

    private func registeredTools(repo: any BlocksRepository) -> [MCPRegisteredTool] {
        let tagsRepo = StubTagsRepoHM()
        let dayRepo = StubDayRepoHM()
        return BlockTools.register(
            blocks: repo,
            tags: tagsRepo,
            days: dayRepo,
            indexCoordinator: indexCoordinator,
            graphService: BlockGraphService()
        )
    }
}

private final class StubDayRepoHM: DayRepository, @unchecked Sendable {
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

private final class StubCaptureRepoHM: CaptureRepository, @unchecked Sendable {
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

private final class StubTagsRepoHM: TagsRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[Tag]> {
        AsyncStream { continuation in
            continuation.yield([])
            continuation.finish()
        }
    }
    func list() async throws -> [Tag] { [] }
    func tag(for id: String) async throws -> Tag? { nil }
    func create(name: String, color: TagColor) async throws -> Tag {
        throw RepositoryError.invalidInput
    }
    func update(_ tag: Tag) async throws -> Tag { tag }
    func delete(id: String) async throws {}
}
