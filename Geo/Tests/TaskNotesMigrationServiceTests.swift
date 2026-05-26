import XCTest
@testable import Geo

@MainActor
final class TaskNotesMigrationServiceTests: XCTestCase {

    private var tempRoot: URL!
    private var tasksStore: TasksStore!
    private var blocksStore: BlocksStore!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-task-notes-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let dayRepository = NoopDayRepository()
        let captureRepository = NoopCaptureRepository()
        let dayManager = DayManager(dayRepository: dayRepository, captureRepository: captureRepository)

        let databaseURL = tempRoot.appendingPathComponent("index.sqlite")
        let database = DatabaseService(databaseURL: databaseURL, fileManager: fm)
        let indexCoordinator = IndexCoordinator(database: database, indexer: MarkdownIndexingService())

        blocksStore = BlocksStore(
            baseURL: tempRoot,
            loadAsync: false,
            enableWatcher: false,
            indexCoordinator: indexCoordinator,
            dayManager: dayManager,
            storageMigration: StorageMigrationService.shared,
            markdownConverter: MarkdownConverter.shared
        )

        tasksStore = TasksStore(baseURL: tempRoot, loadAsync: false)

        defaultsSuiteName = "geo.task-notes-migration.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        try await waitForInitialBlocksLoad()
    }

    private func waitForInitialBlocksLoad() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        for _ in 0..<10 { await Task.yield() }
    }

    override func tearDown() async throws {
        if let suiteName = defaultsSuiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        defaultsSuiteName = nil
        tasksStore = nil
        blocksStore = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - Empty notes

    func testEmptyNotesAreLeftAlone() async throws {
        let task = makeTask(title: "Solo", notes: "")
        tasksStore.importTask(task)

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        let after = tasksStore.task(for: task.id)
        XCTAssertEqual(after?.notes, "")
        XCTAssertNil(after?.linkedBlockId)
        XCTAssertTrue(blocksStore.blocks.isEmpty)
    }

    func testWhitespaceOnlyNotesAreSkipped() async throws {
        let task = makeTask(title: "Whitespace", notes: "   \n\n   ")
        tasksStore.importTask(task)

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        let after = tasksStore.task(for: task.id)
        XCTAssertEqual(after?.notes, "   \n\n   ")
        XCTAssertNil(after?.linkedBlockId)
        XCTAssertTrue(blocksStore.blocks.isEmpty)
    }

    // MARK: - Short notes preserved as future quickNote

    func testShortNotesWithoutLinkedBlockArePreserved() async throws {
        let task = makeTask(title: "Quick", notes: "Pick up packaging")
        tasksStore.importTask(task)

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        let after = tasksStore.task(for: task.id)
        XCTAssertEqual(after?.notes, "Pick up packaging")
        XCTAssertNil(after?.linkedBlockId)
        XCTAssertTrue(blocksStore.blocks.isEmpty)
    }

    // MARK: - Long notes -> create block

    func testLongNotesWithoutLinkedBlockCreateBlockAndClearNotes() async throws {
        let longNotes = String(repeating: "x", count: 250)
        let task = makeTask(title: "Project Phoenix", notes: longNotes)
        tasksStore.importTask(task)

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        let after = tasksStore.task(for: task.id)
        XCTAssertEqual(after?.notes, "")
        XCTAssertNotNil(after?.linkedBlockId)

        let createdBlock = blocksStore.blocks.first { $0.id == after?.linkedBlockId }
        XCTAssertNotNil(createdBlock)
        XCTAssertEqual(createdBlock?.title, "Project Phoenix")
        XCTAssertEqual(createdBlock?.markdown, longNotes)
    }

    func testLongNotesWithEmptyTitleUsesFallbackBlockTitle() async throws {
        let longNotes = String(repeating: "y", count: 250)
        let task = TaskItem(
            id: UUID().uuidString,
            title: "ImportedFromAgent",
            notes: longNotes,
            startTime: Date()
        )
        tasksStore.importTask(task)

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        let after = tasksStore.task(for: task.id)
        XCTAssertEqual(after?.notes, "")
        XCTAssertNotNil(after?.linkedBlockId)

        let createdBlock = blocksStore.blocks.first { $0.id == after?.linkedBlockId }
        XCTAssertEqual(createdBlock?.title, "ImportedFromAgent")
    }

    // MARK: - Notes with linked block -> append

    func testNotesWithLinkedBlockAreAppendedAndCleared() async throws {
        guard let block = await blocksStore.createBlock(title: "Existing", markdown: "# Existing\n\nOriginal body.\n") else {
            return XCTFail("Failed to create seed block")
        }

        let task = makeTask(title: "Linked", notes: "extra context", linkedBlockId: block.id)
        tasksStore.importTask(task)

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        let after = tasksStore.task(for: task.id)
        XCTAssertEqual(after?.notes, "")
        XCTAssertEqual(after?.linkedBlockId, block.id)

        let updatedBlock = blocksStore.blocks.first { $0.id == block.id }
        XCTAssertNotNil(updatedBlock)
        XCTAssertTrue(updatedBlock!.markdown.contains("## Notes (migrated)"))
        XCTAssertTrue(updatedBlock!.markdown.contains("extra context"))
        XCTAssertTrue(updatedBlock!.markdown.contains("Original body."))
    }

    func testLongNotesWithLinkedBlockAppendInsteadOfCreatingNewBlock() async throws {
        guard let block = await blocksStore.createBlock(title: "Container", markdown: "# Container\n") else {
            return XCTFail("Failed to create seed block")
        }

        let longNotes = String(repeating: "z", count: 400)
        let task = makeTask(title: "Big notes linked", notes: longNotes, linkedBlockId: block.id)
        tasksStore.importTask(task)

        let blockCountBefore = blocksStore.blocks.count

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        XCTAssertEqual(blocksStore.blocks.count, blockCountBefore)

        let after = tasksStore.task(for: task.id)
        XCTAssertEqual(after?.notes, "")
        XCTAssertEqual(after?.linkedBlockId, block.id)

        let updated = blocksStore.blocks.first { $0.id == block.id }!
        XCTAssertTrue(updated.markdown.contains("## Notes (migrated)"))
        XCTAssertTrue(updated.markdown.contains(longNotes))
    }

    // MARK: - Linked block missing -> falls through to create new

    func testMissingLinkedBlockCreatesNewBlock() async throws {
        let longNotes = String(repeating: "m", count: 250)
        let task = makeTask(title: "Orphan", notes: longNotes, linkedBlockId: "deleted-block-id.md")
        tasksStore.importTask(task)

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        let after = tasksStore.task(for: task.id)
        XCTAssertEqual(after?.notes, "")
        XCTAssertNotNil(after?.linkedBlockId)
        XCTAssertNotEqual(after?.linkedBlockId, "deleted-block-id.md")

        let created = blocksStore.blocks.first { $0.id == after?.linkedBlockId }
        XCTAssertNotNil(created)
        XCTAssertEqual(created?.markdown, longNotes)
    }

    func testShortNotesWithMissingLinkedBlockStillMigrate() async throws {
        let task = makeTask(title: "Short orphan", notes: "tiny", linkedBlockId: "ghost.md")
        tasksStore.importTask(task)

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        let after = tasksStore.task(for: task.id)
        XCTAssertEqual(after?.notes, "")
        XCTAssertNotNil(after?.linkedBlockId)
        XCTAssertNotEqual(after?.linkedBlockId, "ghost.md")

        let created = blocksStore.blocks.first { $0.id == after?.linkedBlockId }
        XCTAssertEqual(created?.markdown, "tiny")
    }

    // MARK: - Idempotency

    func testRunningTwiceMigratesOnce() async throws {
        let longNotes = String(repeating: "i", count: 250)
        let task = makeTask(title: "Idem", notes: longNotes)
        tasksStore.importTask(task)

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        let blocksAfterFirst = blocksStore.blocks.count
        let linkedAfterFirst = tasksStore.task(for: task.id)?.linkedBlockId

        try await service.runIfNeeded()

        XCTAssertEqual(blocksStore.blocks.count, blocksAfterFirst)
        XCTAssertEqual(tasksStore.task(for: task.id)?.linkedBlockId, linkedAfterFirst)
        XCTAssertTrue(defaults.bool(forKey: TaskNotesMigrationService.migrationKey))
    }

    func testFlagSetAfterSuccessfulRun() async throws {
        let task = makeTask(title: "Empty notes", notes: "")
        tasksStore.importTask(task)

        XCTAssertFalse(defaults.bool(forKey: TaskNotesMigrationService.migrationKey))

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        XCTAssertTrue(defaults.bool(forKey: TaskNotesMigrationService.migrationKey))
    }

    // MARK: - Failure handling

    func testFailureLeavesFlagUnsetForRetry() async throws {
        let fm = FileManager.default
        let altRoot = fm.temporaryDirectory.appendingPathComponent("geo-task-notes-migration-failing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: altRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: altRoot) }

        let dayManager = DayManager(dayRepository: NoopDayRepository(), captureRepository: NoopCaptureRepository())
        let database = DatabaseService(databaseURL: altRoot.appendingPathComponent("idx.sqlite"), fileManager: fm)
        let indexCoordinator = IndexCoordinator(database: database, indexer: MarkdownIndexingService())

        let failingBlocks = AlwaysFailCreateBlocksStore(
            baseURL: altRoot,
            loadAsync: false,
            enableWatcher: false,
            indexCoordinator: indexCoordinator,
            dayManager: dayManager,
            storageMigration: StorageMigrationService.shared,
            markdownConverter: MarkdownConverter.shared
        )

        let task = makeTask(title: "Will fail", notes: String(repeating: "x", count: 250))
        tasksStore.importTask(task)

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: failingBlocks, defaults: defaults)
        try await service.runIfNeeded()

        XCTAssertFalse(defaults.bool(forKey: TaskNotesMigrationService.migrationKey))

        let after = tasksStore.task(for: task.id)
        XCTAssertEqual(after?.notes, task.notes)
        XCTAssertNil(after?.linkedBlockId)
    }

    func testFlagAlreadySetSkipsMigration() async throws {
        let longNotes = String(repeating: "s", count: 250)
        let task = makeTask(title: "Skipped", notes: longNotes)
        tasksStore.importTask(task)

        defaults.set(true, forKey: TaskNotesMigrationService.migrationKey)

        let service = TaskNotesMigrationService(tasksStore: tasksStore, blocksStore: blocksStore, defaults: defaults)
        try await service.runIfNeeded()

        let after = tasksStore.task(for: task.id)
        XCTAssertEqual(after?.notes, longNotes)
        XCTAssertNil(after?.linkedBlockId)
        XCTAssertTrue(blocksStore.blocks.isEmpty)
    }

    // MARK: - Helpers

    private func makeTask(
        title: String,
        notes: String,
        linkedBlockId: String? = nil
    ) -> TaskItem {
        TaskItem(
            id: UUID().uuidString,
            title: title,
            notes: notes,
            linkedBlockId: linkedBlockId,
            status: .pending,
            startTime: Date(),
            createdAt: Date(),
            modifiedAt: Date()
        )
    }
}

private final class NoopDayRepository: DayRepository, @unchecked Sendable {
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

private final class AlwaysFailCreateBlocksStore: BlocksStore {
    override func createBlock(title: String, markdown: String) async -> BlocksStore.Block? {
        nil
    }
}

private final class NoopCaptureRepository: CaptureRepository, @unchecked Sendable {
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
