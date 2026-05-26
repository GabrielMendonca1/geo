import Foundation

extension Notification.Name {
    static let taskMaybeComplete = Notification.Name("taskMaybeComplete")
}

enum TaskMaybeCompleteUserInfoKey {
    static let taskId = "taskId"
    static let blockId = "blockId"
    static let kind = "kind"
}

@MainActor
final class AutoCompleteSuggestionService {
    private let tasksRepository: TasksRepository
    private let notificationCenter: NotificationCenter
    private var observerToken: NSObjectProtocol?

    init(
        tasksRepository: TasksRepository,
        notificationCenter: NotificationCenter = .default
    ) {
        self.tasksRepository = tasksRepository
        self.notificationCenter = notificationCenter
    }

    deinit {
        if let observerToken {
            notificationCenter.removeObserver(observerToken)
        }
    }

    func start() {
        guard observerToken == nil else { return }
        let repository = tasksRepository
        let center = notificationCenter
        observerToken = notificationCenter.addObserver(
            forName: .blockCheckboxesAllCompleted,
            object: nil,
            queue: .main
        ) { notification in
            guard let blockId = notification.userInfo?[BlockCheckboxesAllCompletedUserInfoKey.blockId] as? String,
                  !blockId.isEmpty else {
                return
            }

            Task { @MainActor in
                await Self.dispatchSuggestions(
                    for: blockId,
                    repository: repository,
                    notificationCenter: center
                )
            }
        }
    }

    func stop() {
        if let observerToken {
            notificationCenter.removeObserver(observerToken)
            self.observerToken = nil
        }
    }

    private static func dispatchSuggestions(
        for blockId: String,
        repository: TasksRepository,
        notificationCenter: NotificationCenter
    ) async {
        let allTasks: [TaskItem]
        do {
            allTasks = try await repository.list()
        } catch {
            return
        }

        let pendingLinked = allTasks.filter { task in
            task.linkedBlockId == blockId && task.status == .pending
        }

        for task in pendingLinked {
            let userInfo: [String: Any] = [
                TaskMaybeCompleteUserInfoKey.taskId: task.id,
                TaskMaybeCompleteUserInfoKey.blockId: blockId,
                TaskMaybeCompleteUserInfoKey.kind: task.kind.rawValue
            ]
            notificationCenter.post(
                name: .taskMaybeComplete,
                object: nil,
                userInfo: userInfo
            )
        }
    }
}
