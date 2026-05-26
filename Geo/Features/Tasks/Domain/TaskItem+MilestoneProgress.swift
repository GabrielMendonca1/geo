import Foundation

struct MilestoneProgress: Hashable, Sendable {
    let checkboxStats: CheckboxStats
    let subtaskTotal: Int
    let subtaskCompleted: Int
    let weightedTotal: Double
    let weightedDone: Double

    var percent: Double {
        weightedTotal == 0 ? 0 : weightedDone / weightedTotal
    }

    var isComplete: Bool {
        weightedTotal > 0 && weightedDone >= weightedTotal
    }

    var hasData: Bool {
        weightedTotal > 0
    }
}

extension TaskItem {
    @MainActor
    func milestoneProgress(blocks: BlocksStore?, allTasks: [TaskItem]) -> MilestoneProgress? {
        guard kind == .milestone else { return nil }

        let stats: CheckboxStats
        if let blocks, let blockId = linkedBlockId {
            stats = blocks.checkboxStats(for: blockId)
        } else {
            stats = .empty
        }

        let subtasks = allTasks.filter { $0.parentId == id }
        let subtaskTotal = subtasks.count
        let subtaskCompleted = subtasks.filter { $0.status == .completed }.count

        let subtaskWeight: (TaskItem) -> Double = { task in
            if let minutes = task.estimatedMinutes, minutes > 0 {
                return Double(minutes)
            }
            return 1
        }

        let subtaskWeightedTotal = subtasks.reduce(0.0) { $0 + subtaskWeight($1) }
        let subtaskWeightedDone = subtasks
            .filter { $0.status == .completed }
            .reduce(0.0) { $0 + subtaskWeight($1) }

        let weightedTotal = Double(stats.total) + subtaskWeightedTotal
        let weightedDone = Double(stats.checked) + subtaskWeightedDone

        guard weightedTotal > 0 else { return nil }

        return MilestoneProgress(
            checkboxStats: stats,
            subtaskTotal: subtaskTotal,
            subtaskCompleted: subtaskCompleted,
            weightedTotal: weightedTotal,
            weightedDone: weightedDone
        )
    }
}
