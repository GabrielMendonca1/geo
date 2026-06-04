import XCTest
@testable import Geo

@MainActor
final class BlocksStoreCheckboxTests: XCTestCase {

    private var tempRoot: URL!
    private var store: BlocksStore!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-blockcheckbox-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let dayRepository = StubDayRepository()
        let captureRepository = StubCaptureRepository()
        let dayManager = DayManager(dayRepository: dayRepository, captureRepository: captureRepository)

        let databaseURL = tempRoot.appendingPathComponent("index.sqlite")
        let database = DatabaseService(databaseURL: databaseURL, fileManager: fm)
        let indexCoordinator = IndexCoordinator(database: database, indexer: MarkdownIndexingService())

        store = BlocksStore(
            baseURL: tempRoot,
            loadAsync: false,
            enableWatcher: false,
            indexCoordinator: indexCoordinator,
            dayManager: dayManager,
            markdownConverter: MarkdownConverter.shared
        )
    }

    override func tearDown() async throws {
        store = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    private func makeBlock(markdown: String, title: String = "Test") async throws -> BlocksStore.Block {
        let unique = "\(title)-\(UUID().uuidString.prefix(8))"
        guard let block = await store.createBlock(title: unique, markdown: markdown) else {
            throw XCTSkip("Block creation returned nil")
        }
        return block
    }

    func testCheckboxesReturnsMixedCheckboxesWithLineNumbers() async throws {
        let markdown = """
        # Heading

        Some intro text.

        - [ ] first task
        - [x] second task
        - regular bullet
        - [X] uppercase done
        """
        let block = try await makeBlock(markdown: markdown)

        let checkboxes = store.checkboxes(in: block.id)

        XCTAssertEqual(checkboxes.count, 3)
        XCTAssertEqual(checkboxes[0].text, "first task")
        XCTAssertEqual(checkboxes[0].checked, false)
        XCTAssertEqual(checkboxes[0].lineNumber, 5)

        XCTAssertEqual(checkboxes[1].text, "second task")
        XCTAssertEqual(checkboxes[1].checked, true)
        XCTAssertEqual(checkboxes[1].lineNumber, 6)

        XCTAssertEqual(checkboxes[2].text, "uppercase done")
        XCTAssertEqual(checkboxes[2].checked, true)
        XCTAssertEqual(checkboxes[2].lineNumber, 8)
    }

    func testCheckboxesReturnsEmptyForBlockWithoutCheckboxes() async throws {
        let markdown = "# Just a note\n\nNo checkboxes here.\n- a regular bullet\n"
        let block = try await makeBlock(markdown: markdown)

        let checkboxes = store.checkboxes(in: block.id)
        XCTAssertTrue(checkboxes.isEmpty)
    }

    func testCheckboxesReturnsEmptyForMissingBlock() {
        let checkboxes = store.checkboxes(in: "does-not-exist.md")
        XCTAssertTrue(checkboxes.isEmpty)
    }

    func testCheckboxesIgnoresFencedCodeBlocks() async throws {
        let markdown = """
        - [ ] real task

        ```
        - [ ] fake task in code
        - [x] also fake
        ```

        - [x] another real task
        """
        let block = try await makeBlock(markdown: markdown)

        let checkboxes = store.checkboxes(in: block.id)
        XCTAssertEqual(checkboxes.count, 2)
        XCTAssertEqual(checkboxes[0].text, "real task")
        XCTAssertEqual(checkboxes[0].checked, false)
        XCTAssertEqual(checkboxes[1].text, "another real task")
        XCTAssertEqual(checkboxes[1].checked, true)
    }

    func testToggleCheckboxFlipsUncheckedToChecked() async throws {
        let markdown = "# Title\n\n- [ ] todo item\n"
        let block = try await makeBlock(markdown: markdown)

        try await store.toggleCheckbox(in: block.id, lineNumber: 3)

        let updated = store.checkboxes(in: block.id)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].checked, true)
        XCTAssertEqual(updated[0].text, "todo item")

        let stored = store.blocks.first(where: { $0.id == block.id })
        XCTAssertNotNil(stored)
        XCTAssertTrue(stored!.markdown.contains("- [x] todo item"))
    }

    func testToggleCheckboxFlipsCheckedToUnchecked() async throws {
        let markdown = "- [x] done item\n"
        let block = try await makeBlock(markdown: markdown)

        try await store.toggleCheckbox(in: block.id, lineNumber: 1)

        let updated = store.checkboxes(in: block.id)
        XCTAssertEqual(updated[0].checked, false)
        let stored = store.blocks.first(where: { $0.id == block.id })!
        XCTAssertTrue(stored.markdown.contains("- [ ] done item"))
    }

    func testToggleCheckboxThrowsForNonCheckboxLine() async throws {
        let markdown = "Just a paragraph.\n"
        let block = try await makeBlock(markdown: markdown)

        do {
            try await store.toggleCheckbox(in: block.id, lineNumber: 1)
            XCTFail("Expected toggle to throw")
        } catch let error as BlockCheckboxError {
            XCTAssertEqual(error, .notACheckbox)
        }
    }

    func testToggleCheckboxThrowsForMissingBlock() async throws {
        do {
            try await store.toggleCheckbox(in: "missing.md", lineNumber: 1)
            XCTFail("Expected toggle to throw")
        } catch let error as BlockCheckboxError {
            XCTAssertEqual(error, .blockNotFound)
        }
    }

    func testResetCheckedCheckboxesReturnsSnapshotsAndUnchecksAll() async throws {
        let markdown = """
        - [ ] still open
        - [x] was checked
        - [X] also checked
        """
        let block = try await makeBlock(markdown: markdown)

        let snapshots = try await store.resetCheckedCheckboxes(in: block.id)

        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots[0], BlockCheckboxSnapshot(text: "still open", wasChecked: false))
        XCTAssertEqual(snapshots[1], BlockCheckboxSnapshot(text: "was checked", wasChecked: true))
        XCTAssertEqual(snapshots[2], BlockCheckboxSnapshot(text: "also checked", wasChecked: true))

        let after = store.checkboxes(in: block.id)
        XCTAssertEqual(after.count, 3)
        XCTAssertTrue(after.allSatisfy { !$0.checked })

        let stored = store.blocks.first(where: { $0.id == block.id })!
        XCTAssertFalse(stored.markdown.contains("[x]"))
        XCTAssertFalse(stored.markdown.contains("[X]"))
    }

    func testResetCheckedCheckboxesIgnoresCodeBlocks() async throws {
        let markdown = """
        - [x] real one

        ```
        - [x] fake one
        ```
        """
        let block = try await makeBlock(markdown: markdown)

        let snapshots = try await store.resetCheckedCheckboxes(in: block.id)

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].text, "real one")

        let stored = store.blocks.first(where: { $0.id == block.id })!
        XCTAssertTrue(stored.markdown.contains("- [ ] real one"))
        XCTAssertTrue(stored.markdown.contains("- [x] fake one"))
    }

    func testConsecutiveCheckboxesParseAndToggleCorrectly() async throws {
        let markdown = """
        - [ ] one
        - [ ] two
        - [ ] three
        - [ ] four
        """
        let block = try await makeBlock(markdown: markdown)

        let initial = store.checkboxes(in: block.id)
        XCTAssertEqual(initial.count, 4)
        XCTAssertEqual(initial.map(\.lineNumber), [1, 2, 3, 4])
        XCTAssertEqual(initial.map(\.text), ["one", "two", "three", "four"])

        try await store.toggleCheckbox(in: block.id, lineNumber: 2)
        try await store.toggleCheckbox(in: block.id, lineNumber: 4)

        let after = store.checkboxes(in: block.id)
        XCTAssertEqual(after.map(\.checked), [false, true, false, true])

        let stored = store.blocks.first(where: { $0.id == block.id })!
        XCTAssertTrue(stored.markdown.contains("- [ ] one"))
        XCTAssertTrue(stored.markdown.contains("- [x] two"))
        XCTAssertTrue(stored.markdown.contains("- [ ] three"))
        XCTAssertTrue(stored.markdown.contains("- [x] four"))
    }

    func testCheckboxesSupportOrderedListMarkers() async throws {
        let markdown = """
        1. [ ] numbered open
        2. [x] numbered done
        """
        let block = try await makeBlock(markdown: markdown)

        let checkboxes = store.checkboxes(in: block.id)
        XCTAssertEqual(checkboxes.count, 2)
        XCTAssertEqual(checkboxes[0].text, "numbered open")
        XCTAssertEqual(checkboxes[0].checked, false)
        XCTAssertEqual(checkboxes[1].text, "numbered done")
        XCTAssertEqual(checkboxes[1].checked, true)
    }
}

private final class StubDayRepository: DayRepository, @unchecked Sendable {
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

private final class StubCaptureRepository: CaptureRepository, @unchecked Sendable {
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
