import Foundation
import GeoCore

enum HabitCompletionError: Error, Equatable {
    case taskNotFound
    case notAHabit
}

protocol HabitCheckboxProvider {
    @MainActor func checkboxes(in blockId: String) -> [BlockCheckbox]
    @MainActor @discardableResult
    func resetCheckedCheckboxes(in blockId: String) async throws -> [BlockCheckboxSnapshot]
}

extension BlocksStore: HabitCheckboxProvider {}

protocol HabitTaskPersisting: AnyObject {
    @MainActor func task(for id: String) -> TaskItem?
    @MainActor func replaceTask(_ task: TaskItem)
}

extension TasksStore {
    @MainActor
    func completeHabitOccurrence(
        taskId: String,
        blocksStore: any HabitCheckboxProvider,
        at date: Date = Date()
    ) async throws {
        try await Self.completeHabitOccurrence(
            taskId: taskId,
            blocksStore: blocksStore,
            at: date,
            persister: TasksStoreHabitPersister(store: self)
        )
    }

    @MainActor
    static func completeHabitOccurrence(
        taskId: String,
        blocksStore: any HabitCheckboxProvider,
        at date: Date,
        persister: any HabitTaskPersisting
    ) async throws {
        guard var task = persister.task(for: taskId) else {
            throw HabitCompletionError.taskNotFound
        }
        guard case .habit(let rule, let timeOfDay, var occurrences) = task.body else {
            throw HabitCompletionError.notAHabit
        }

        let cal = Calendar.current
        if occurrences.contains(where: { cal.isDate($0, inSameDayAs: date) }) {
            return
        }
        occurrences.append(date)

        if let blockId = task.linkedBlockId {
            _ = try await blocksStore.resetCheckedCheckboxes(in: blockId)
        }

        // Advance the anchor (timeOfDay carries the next occurrence's date)
        let advancedTimeOfDay: Date
        if let next = rule.nextDate(after: timeOfDay) {
            advancedTimeOfDay = next
            task.status = .pending
        } else {
            advancedTimeOfDay = timeOfDay
            task.status = .completed
        }

        task.body = .habit(rule: rule, timeOfDay: advancedTimeOfDay, occurrences: occurrences)
        task.reminders = task.reminders.map { var r = $0; r.fired = false; return r }
        task.modifiedAt = Date()

        persister.replaceTask(task)
    }
}

private final class TasksStoreHabitPersister: HabitTaskPersisting {
    private let store: TasksStore

    init(store: TasksStore) { self.store = store }

    @MainActor func task(for id: String) -> TaskItem? { store.task(for: id) }
    @MainActor func replaceTask(_ task: TaskItem) { store.replaceTask(task) }
}
