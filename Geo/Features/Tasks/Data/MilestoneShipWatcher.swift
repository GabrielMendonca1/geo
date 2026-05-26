import Foundation
import Combine

@MainActor
final class MilestoneShipWatcher: ObservableObject {
    struct PendingShip: Identifiable, Equatable {
        let milestone: TaskItem
        var id: String { milestone.id }
    }

    @Published var pendingShip: PendingShip?

    private let tasksStore: TasksStore
    private let notificationCenter: NotificationCenter
    private var cancellables: Set<AnyCancellable> = []
    private var snoozedMilestoneIds: Set<String> = []

    init(tasksStore: TasksStore, notificationCenter: NotificationCenter = .default) {
        self.tasksStore = tasksStore
        self.notificationCenter = notificationCenter

        notificationCenter.publisher(for: .blockCheckboxesAllCompleted)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handle(notification: notification)
            }
            .store(in: &cancellables)
    }

    private func handle(notification: Notification) {
        guard let blockId = notification.userInfo?[BlockCheckboxesAllCompletedUserInfoKey.blockId] as? String,
              !blockId.isEmpty else {
            return
        }

        guard let milestone = tasksStore.tasks.first(where: { task in
            task.kind == .milestone
                && task.linkedBlockId == blockId
                && task.status == .pending
        }) else {
            return
        }

        if snoozedMilestoneIds.contains(milestone.id) {
            snoozedMilestoneIds.remove(milestone.id)
        }

        pendingShip = PendingShip(milestone: milestone)
    }

    func shipIt() {
        guard let ship = pendingShip else { return }
        let milestone = ship.milestone
        tasksStore.updateTask(
            id: milestone.id,
            title: milestone.title,
            notes: milestone.notes,
            linkedBlockId: milestone.linkedBlockId,
            startTime: milestone.startTime,
            endTime: milestone.endTime,
            reminders: milestone.reminders,
            recurringReminders: milestone.recurringReminders,
            recurrence: milestone.recurrence,
            smartReminder: milestone.smartReminder,
            status: .completed,
            kind: milestone.kind,
            priority: milestone.priority,
            tagIds: milestone.tagIds,
            parentId: milestone.parentId,
            estimatedMinutes: milestone.estimatedMinutes,
            context: milestone.context,
            horizon: milestone.horizon
        )
        pendingShip = nil
    }

    func dismiss() {
        pendingShip = nil
    }

    func snooze() {
        if let ship = pendingShip {
            snoozedMilestoneIds.insert(ship.id)
        }
        pendingShip = nil
    }
}
