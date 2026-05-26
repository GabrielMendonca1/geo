import Foundation

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
        guard task.kind == .habit else {
            throw HabitCompletionError.notAHabit
        }

        let snapshot: [CheckboxSnapshot]
        if let blockId = task.linkedBlockId {
            snapshot = blocksStore.checkboxes(in: blockId).map {
                CheckboxSnapshot(text: $0.text, wasChecked: $0.checked)
            }
        } else {
            snapshot = []
        }

        var habitState = task.habitState ?? HabitState()
        if habitState.occurrences.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) {
            return
        }
        habitState.occurrences.append(HabitOccurrence(date: date, checkboxes: snapshot))
        let streaks = computeStreaks(history: habitState.occurrences.map(\.date))
        habitState.currentStreak = streaks.current
        habitState.longestStreak = max(habitState.longestStreak, streaks.longest)

        if let blockId = task.linkedBlockId, habitState.resetCheckboxesOnComplete {
            _ = try await blocksStore.resetCheckedCheckboxes(in: blockId)
        }

        task.habitState = habitState
        task.completionHistory = habitState.occurrences.map(\.date)
        task.currentStreak = habitState.currentStreak
        task.longestStreak = habitState.longestStreak
        task.firedReminders = []
        task.modifiedAt = Date()

        if case .recurring(let rule, let timeOfDay) = task.schedule {
            if let nextDate = rule.nextDate(after: task.startTime) {
                task.startTime = nextDate
                task.schedule = .recurring(rule: rule, timeOfDay: timeOfDay)
                task.status = .pending
            } else {
                task.status = .completed
            }
        } else if let nextDate = task.recurrence.nextDate(after: task.startTime) {
            task.startTime = nextDate
            task.status = .pending
        } else {
            task.status = .completed
        }

        persister.replaceTask(task)
    }

    static func computeStreaks(history: [Date], calendar: Calendar = .current) -> (current: Int, longest: Int) {
        guard !history.isEmpty else { return (0, 0) }
        let sortedDays = history
            .map { calendar.startOfDay(for: $0) }
            .sorted()
        var current = 1
        var longest = 1
        var run = 1
        for i in 1..<sortedDays.count {
            let gap = calendar.dateComponents([.day], from: sortedDays[i - 1], to: sortedDays[i]).day ?? 0
            if gap == 0 {
                continue
            } else if gap == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }
        current = run
        return (current, longest)
    }
}

private final class TasksStoreHabitPersister: HabitTaskPersisting {
    private let store: TasksStore

    init(store: TasksStore) {
        self.store = store
    }

    @MainActor
    func task(for id: String) -> TaskItem? {
        store.task(for: id)
    }

    @MainActor
    func replaceTask(_ task: TaskItem) {
        store.replaceTask(task)
    }
}
