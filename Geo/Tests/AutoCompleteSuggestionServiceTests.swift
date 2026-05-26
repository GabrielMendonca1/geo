import XCTest
@testable import Geo

final class AutoCompleteSuggestionServiceTests: XCTestCase {
    private var notificationCenter: NotificationCenter!
    private var indexer: MarkdownIndexingService!

    override func setUp() {
        super.setUp()
        notificationCenter = NotificationCenter()
        indexer = MarkdownIndexingService()
    }

    override func tearDown() {
        notificationCenter = nil
        indexer = nil
        super.tearDown()
    }

    // MARK: - MarkdownIndexingService notification emission

    func testEmitFiresWhenOpenCountTransitionsToZeroWithCompletions() {
        let expectation = expectation(description: "blockCheckboxesAllCompleted posted")
        var receivedUserInfo: [AnyHashable: Any]?

        let observer = notificationCenter.addObserver(
            forName: .blockCheckboxesAllCompleted,
            object: nil,
            queue: nil
        ) { notification in
            receivedUserInfo = notification.userInfo
            expectation.fulfill()
        }
        defer { notificationCenter.removeObserver(observer) }

        indexer.emitCheckboxCompletionIfNeeded(
            blockId: "block-1",
            priorOpenCount: 3,
            newOpenCount: 0,
            newCompletedCount: 3,
            notificationCenter: notificationCenter
        )

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedUserInfo?[BlockCheckboxesAllCompletedUserInfoKey.blockId] as? String, "block-1")
        XCTAssertEqual(receivedUserInfo?[BlockCheckboxesAllCompletedUserInfoKey.completedCount] as? Int, 3)
    }

    func testEmitDoesNotFireWhenBlockNeverHadCheckboxes() {
        let expectation = expectation(description: "no notification posted")
        expectation.isInverted = true

        let observer = notificationCenter.addObserver(
            forName: .blockCheckboxesAllCompleted,
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        defer { notificationCenter.removeObserver(observer) }

        indexer.emitCheckboxCompletionIfNeeded(
            blockId: "block-2",
            priorOpenCount: 0,
            newOpenCount: 0,
            newCompletedCount: 0,
            notificationCenter: notificationCenter
        )

        wait(for: [expectation], timeout: 0.3)
    }

    func testEmitDoesNotFireWhenSomeOpenItemsRemain() {
        let expectation = expectation(description: "no notification posted")
        expectation.isInverted = true

        let observer = notificationCenter.addObserver(
            forName: .blockCheckboxesAllCompleted,
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        defer { notificationCenter.removeObserver(observer) }

        indexer.emitCheckboxCompletionIfNeeded(
            blockId: "block-3",
            priorOpenCount: 3,
            newOpenCount: 1,
            newCompletedCount: 2,
            notificationCenter: notificationCenter
        )

        wait(for: [expectation], timeout: 0.3)
    }

    func testEmitDoesNotFireWhenCompletedCountIsZero() {
        let expectation = expectation(description: "no notification posted")
        expectation.isInverted = true

        let observer = notificationCenter.addObserver(
            forName: .blockCheckboxesAllCompleted,
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        defer { notificationCenter.removeObserver(observer) }

        indexer.emitCheckboxCompletionIfNeeded(
            blockId: "block-4",
            priorOpenCount: 2,
            newOpenCount: 0,
            newCompletedCount: 0,
            notificationCenter: notificationCenter
        )

        wait(for: [expectation], timeout: 0.3)
    }

    // MARK: - AutoCompleteSuggestionService

    @MainActor
    func testServicePostsTaskMaybeCompleteForEachLinkedPendingTask() async throws {
        let blockId = "block-A"
        let tasks: [TaskItem] = [
            makeTask(id: "t-1", linkedBlockId: blockId, status: .pending, kind: .task),
            makeTask(id: "t-2", linkedBlockId: blockId, status: .pending, kind: .habit),
            makeTask(id: "t-3", linkedBlockId: blockId, status: .completed, kind: .task),
            makeTask(id: "t-4", linkedBlockId: "other-block", status: .pending, kind: .task),
            makeTask(id: "t-5", linkedBlockId: nil, status: .pending, kind: .task)
        ]
        let repository = StubTasksRepository(tasks: tasks)
        let service = AutoCompleteSuggestionService(
            tasksRepository: repository,
            notificationCenter: notificationCenter
        )
        service.start()
        defer { service.stop() }

        let collected = NotificationCollector(
            center: notificationCenter,
            name: .taskMaybeComplete
        )

        notificationCenter.post(
            name: .blockCheckboxesAllCompleted,
            object: nil,
            userInfo: [
                BlockCheckboxesAllCompletedUserInfoKey.blockId: blockId,
                BlockCheckboxesAllCompletedUserInfoKey.completedCount: 4
            ]
        )

        try await collected.waitFor(count: 2, timeout: 1.0)

        let received = collected.notifications
        let receivedTaskIds = Set(received.compactMap {
            $0.userInfo?[TaskMaybeCompleteUserInfoKey.taskId] as? String
        })
        XCTAssertEqual(receivedTaskIds, ["t-1", "t-2"])

        let receivedKinds = received.compactMap {
            $0.userInfo?[TaskMaybeCompleteUserInfoKey.kind] as? String
        }
        XCTAssertTrue(receivedKinds.contains("task"))
        XCTAssertTrue(receivedKinds.contains("habit"))

        for notification in received {
            XCTAssertEqual(
                notification.userInfo?[TaskMaybeCompleteUserInfoKey.blockId] as? String,
                blockId
            )
        }
    }

    @MainActor
    func testServiceEmitsNothingWhenNoLinkedTasks() async throws {
        let repository = StubTasksRepository(tasks: [
            makeTask(id: "t-9", linkedBlockId: "unrelated", status: .pending, kind: .task)
        ])
        let service = AutoCompleteSuggestionService(
            tasksRepository: repository,
            notificationCenter: notificationCenter
        )
        service.start()
        defer { service.stop() }

        let collected = NotificationCollector(
            center: notificationCenter,
            name: .taskMaybeComplete
        )

        notificationCenter.post(
            name: .blockCheckboxesAllCompleted,
            object: nil,
            userInfo: [
                BlockCheckboxesAllCompletedUserInfoKey.blockId: "ghost-block",
                BlockCheckboxesAllCompletedUserInfoKey.completedCount: 1
            ]
        )

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(collected.notifications.count, 0)
    }

    @MainActor
    func testServiceStopUnsubscribes() async throws {
        let repository = StubTasksRepository(tasks: [
            makeTask(id: "t-x", linkedBlockId: "block-Z", status: .pending, kind: .task)
        ])
        let service = AutoCompleteSuggestionService(
            tasksRepository: repository,
            notificationCenter: notificationCenter
        )
        service.start()
        service.stop()

        let collected = NotificationCollector(
            center: notificationCenter,
            name: .taskMaybeComplete
        )

        notificationCenter.post(
            name: .blockCheckboxesAllCompleted,
            object: nil,
            userInfo: [
                BlockCheckboxesAllCompletedUserInfoKey.blockId: "block-Z",
                BlockCheckboxesAllCompletedUserInfoKey.completedCount: 1
            ]
        )

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(collected.notifications.count, 0)
    }

    // MARK: - Helpers

    private func makeTask(
        id: String,
        linkedBlockId: String?,
        status: TaskStatus,
        kind: TaskKind
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: "Task \(id)",
            linkedBlockId: linkedBlockId,
            status: status,
            startTime: Date(timeIntervalSince1970: 0),
            kind: kind
        )
    }
}

private final class StubTasksRepository: TasksRepository, @unchecked Sendable {
    private let tasks: [TaskItem]

    init(tasks: [TaskItem]) {
        self.tasks = tasks
    }

    func observe() -> AsyncStream<[TaskItem]> {
        AsyncStream { continuation in
            continuation.yield(tasks)
            continuation.finish()
        }
    }

    func importTask(_ task: TaskItem) async throws {}

    func list() async throws -> [TaskItem] {
        tasks
    }

    func create(_ draft: TaskDraft) async throws -> TaskItem {
        throw RepositoryError.invalidInput
    }

    func update(_ task: TaskItem) async throws {}

    func delete(id: String) async throws {}
}

private final class NotificationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _notifications: [Notification] = []
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    var notifications: [Notification] {
        lock.lock()
        defer { lock.unlock() }
        return _notifications
    }

    init(center: NotificationCenter, name: Notification.Name) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            self.lock.lock()
            self._notifications.append(note)
            self.lock.unlock()
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }

    func waitFor(count: Int, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if notifications.count >= count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if notifications.count < count {
            throw NotificationWaitError.timeout(expected: count, got: notifications.count)
        }
    }
}

private enum NotificationWaitError: Error {
    case timeout(expected: Int, got: Int)
}
