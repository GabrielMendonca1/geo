import Foundation
import Combine

protocol TasksStoreAccess: Sendable {
    func observeTasks() -> AsyncStream<[TaskItem]>
    func importTask(_ task: TaskItem) async -> Bool
    func allTasks() async -> [TaskItem]
    func createTask(from draft: TaskDraft) async -> TaskItem?
    func updateTask(_ task: TaskItem) async -> Bool
    func deleteTask(id: String) async -> Bool
}

private final class TasksObservationBox: @unchecked Sendable {
    var cancellable: AnyCancellable?
}

final class LiveTasksStoreAccess: TasksStoreAccess, @unchecked Sendable {
    private let tasksStore: TasksStore

    init(tasksStore: TasksStore) {
        self.tasksStore = tasksStore
    }

    func observeTasks() -> AsyncStream<[TaskItem]> {
        AsyncStream { continuation in
            let box = TasksObservationBox()
            let setupTask = Task { @MainActor [tasksStore] in
                continuation.yield(tasksStore.tasks)
                var lastCount = tasksStore.tasks.count
                var lastModified = tasksStore.tasks.map(\.modifiedAt)
                box.cancellable = tasksStore.$tasks
                    .dropFirst()
                    .sink { tasks in
                        let newCount = tasks.count
                        let newModified = tasks.map(\.modifiedAt)
                        if newCount != lastCount || newModified != lastModified {
                            lastCount = newCount
                            lastModified = newModified
                            continuation.yield(tasks)
                        }
                    }
            }

            continuation.onTermination = { @Sendable _ in
                setupTask.cancel()
                Task { @MainActor in
                    box.cancellable?.cancel()
                    box.cancellable = nil
                }
            }
        }
    }

    func allTasks() async -> [TaskItem] {
        await MainActor.run {
            tasksStore.tasks
        }
    }

    func importTask(_ task: TaskItem) async -> Bool {
        await MainActor.run {
            guard tasksStore.task(for: task.id) == nil else {
                return false
            }
            tasksStore.importTask(task)
            return true
        }
    }

    func createTask(from draft: TaskDraft) async -> TaskItem? {
        await MainActor.run {
            tasksStore.createTask(
                title: draft.title,
                notes: draft.notes,
                linkedBlockId: draft.linkedBlockId,
                startTime: draft.startTime,
                endTime: draft.endTime,
                reminders: draft.reminders,
                recurringReminders: draft.recurringReminders,
                recurrence: draft.recurrence,
                smartReminder: draft.smartReminder,
                kind: draft.kind,
                priority: draft.priority,
                tagIds: draft.tagIds,
                parentId: draft.parentId,
                estimatedMinutes: draft.estimatedMinutes,
                context: draft.context
            )
        }
    }

    func updateTask(_ task: TaskItem) async -> Bool {
        await MainActor.run {
            guard tasksStore.task(for: task.id) != nil else {
                return false
            }
            tasksStore.updateTask(
                id: task.id,
                title: task.title,
                notes: task.notes,
                linkedBlockId: task.linkedBlockId,
                startTime: task.startTime,
                endTime: task.endTime,
                reminders: task.reminders,
                recurringReminders: task.recurringReminders,
                recurrence: task.recurrence,
                smartReminder: task.smartReminder,
                status: task.status,
                kind: task.kind,
                priority: task.priority,
                tagIds: task.tagIds,
                parentId: task.parentId,
                estimatedMinutes: task.estimatedMinutes,
                context: task.context
            )
            return true
        }
    }

    func deleteTask(id: String) async -> Bool {
        await MainActor.run {
            guard tasksStore.task(for: id) != nil else {
                return false
            }
            tasksStore.deleteTask(id: id)
            return true
        }
    }
}

struct TasksStoreRepositoryAdapter: TasksRepository, @unchecked Sendable {
    private let storeAccess: any TasksStoreAccess

    init(tasksStore: TasksStore) {
        self.storeAccess = LiveTasksStoreAccess(tasksStore: tasksStore)
    }

    init(storeAccess: any TasksStoreAccess) {
        self.storeAccess = storeAccess
    }

    func observe() -> AsyncStream<[TaskItem]> {
        storeAccess.observeTasks()
    }

    func list() async throws -> [TaskItem] {
        await storeAccess.allTasks()
    }

    func importTask(_ task: TaskItem) async throws {
        guard !task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let imported = await storeAccess.importTask(task)
        guard imported else {
            throw RepositoryError.invalidInput
        }
    }

    func create(_ draft: TaskDraft) async throws -> TaskItem {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        guard let task = await storeAccess.createTask(from: draft) else {
            throw RepositoryError.invalidInput
        }
        return task
    }

    func update(_ task: TaskItem) async throws {
        guard !task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let updated = await storeAccess.updateTask(task)
        guard updated else {
            throw RepositoryError.notFound
        }
    }

    func delete(id: String) async throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let deleted = await storeAccess.deleteTask(id: id)
        if !deleted {
            throw RepositoryError.notFound
        }
    }
}
