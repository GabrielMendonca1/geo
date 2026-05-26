import Foundation

extension TasksStore {
    @MainActor
    @discardableResult
    func revertExpiredDayHorizons(now: Date = Date()) -> Int {
        let startOfToday = Calendar.current.startOfDay(for: now)
        let expired = tasks.filter { task in
            task.horizon == .day
                && task.status == .pending
                && task.startTime < startOfToday
                && !task.recurrence.isRepeating
        }
        for task in expired {
            var updated = task
            updated.horizon = .week
            replaceTask(updated)
        }
        return expired.count
    }
}
