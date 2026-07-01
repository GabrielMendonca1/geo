import Combine
import Foundation
import GeoCore

@MainActor
final class TasksViewModel: ObservableObject {
    @Published private(set) var pending: [ReminderItem] = []
    @Published private(set) var completed: [ReminderItem] = []
    @Published private(set) var isLoading = false

    private let service: EventKitService
    private var cancellable: AnyCancellable?

    init(service: EventKitService = .shared) {
        self.service = service
        cancellable = service.$changeToken
            .dropFirst()
            .sink { [weak self] _ in
                Task { await self?.reload() }
            }
    }

    var isAuthorized: Bool { service.isRemindersAuthorized }

    func requestAccess() async {
        await service.requestAccess()
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let all = await service.fetchReminders()
        let sorted = all.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?): return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.title < rhs.title
            }
        }
        pending = sorted.filter { !$0.isCompleted }
        completed = sorted.filter { $0.isCompleted }
    }

    func toggle(_ reminder: ReminderItem) {
        service.toggleCompleted(reminderID: reminder.id)
    }

    func dueLabel(for reminder: ReminderItem) -> String? {
        guard let due = reminder.dueDate else { return nil }
        return MobileDateFormatters.mediumDate.string(from: due)
    }
}
