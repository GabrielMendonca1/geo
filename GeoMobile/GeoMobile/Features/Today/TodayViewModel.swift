import Combine
import EventKit
import Foundation
import GeoCore

enum AgendaEntry: Identifiable {
    case task(TaskItem)
    case event(CalendarEventItem)

    var id: String {
        switch self {
        case .task(let task): return "task-" + task.id
        case .event(let event): return event.id
        }
    }

    var sortStart: Date {
        switch self {
        case .task(let task): return task.anchorDate
        case .event(let event): return event.start
        }
    }

    var isAllDay: Bool {
        switch self {
        case .task(let task): return task.resolvedIsAllDay
        case .event(let event): return event.isAllDay
        }
    }

    var sortTitle: String {
        switch self {
        case .task(let task): return task.title
        case .event(let event): return event.title
        }
    }
}

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var overdue: [TaskItem] = []
    @Published private(set) var todayAgenda: [AgendaEntry] = []
    @Published private(set) var upcoming: [TaskItem] = []
    @Published private(set) var completedToday: [TaskItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?

    private var today: [TaskItem] = []
    private var eventEntries: [AgendaEntry] = []

    private let service: EventKitService
    private let repository: BridgeTasksRepository
    private var cancellable: AnyCancellable?

    init(service: EventKitService? = nil, repository: BridgeTasksRepository = BridgeTasksRepository()) {
        self.service = service ?? .shared
        self.repository = repository
        cancellable = self.service.$changeToken
            .dropFirst()
            .sink { [weak self] _ in
                Task { await self?.reload() }
            }
    }

    var isAuthorized: Bool { service.isCalendarAuthorized }

    var dayTitle: String { "Today" }

    var isEmpty: Bool {
        overdue.isEmpty && todayAgenda.isEmpty && upcoming.isEmpty && completedToday.isEmpty
    }

    private var dayInterval: DateInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    func requestAccess() async {
        await service.requestAccess()
        await reload()
    }

    func reload() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        let cal = Calendar.current
        var tasks: [TaskItem] = []
        do {
            tasks = try await repository.list()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        apply(tasks)

        var mirroredKeys = Set<String>()
        for task in tasks {
            guard task.status == .pending,
                  case .task(let due, _) = task.body,
                  cal.isDateInToday(due) else { continue }
            if task.externalEKEventID != nil {
                mirroredKeys.insert(Self.mirrorKey(title: task.title, start: due, isAllDay: task.resolvedIsAllDay))
            }
        }

        eventEntries = service.events(in: dayInterval)
            .filter { !mirroredKeys.contains(Self.mirrorKey(title: $0.title, start: $0.start, isAllDay: $0.isAllDay)) }
            .map { AgendaEntry.event($0) }

        rebuildAgenda()
    }

    func complete(_ task: TaskItem) {
        var done = task
        done.status = .completed
        done.modifiedAt = Date()
        applyPending(pending.filter { $0.id != task.id })
        completedToday.insert(done, at: 0)
        Task {
            do {
                try await repository.completeTask(id: task.id)
                errorMessage = nil
            } catch {
                completedToday.removeAll { $0.id == task.id }
                applyPending(pending.filter { $0.id != task.id } + [task])
                errorMessage = error.localizedDescription
            }
        }
    }

    func reopen(_ task: TaskItem) {
        var reopened = task
        reopened.status = .pending
        reopened.modifiedAt = Date()
        completedToday.removeAll { $0.id == task.id }
        applyPending(pending.filter { $0.id != task.id } + [reopened])
        Task {
            do {
                try await repository.reopenTask(id: task.id)
                errorMessage = nil
            } catch {
                applyPending(pending.filter { $0.id != task.id })
                completedToday.removeAll { $0.id == task.id }
                completedToday.insert(task, at: 0)
                errorMessage = error.localizedDescription
            }
        }
    }

    func create(_ draft: TaskDraft) {
        let provisional = TaskItem(
            id: UUID().uuidString,
            title: draft.title,
            linkedBlockId: draft.linkedBlockId,
            status: draft.status,
            priority: draft.priority,
            tagIds: draft.tagIds,
            orderIndex: draft.orderIndex,
            estimatedMinutes: draft.estimatedMinutes,
            body: draft.body,
            reminders: draft.reminders
        )
        applyPending(pending + [provisional])
        Task {
            do {
                let created = try await repository.create(provisional)
                applyPending(pending.filter { $0.id != provisional.id && $0.id != created.id } + [created])
                errorMessage = nil
            } catch {
                applyPending(pending.filter { $0.id != provisional.id })
                errorMessage = error.localizedDescription
            }
        }
    }

    private var pending: [TaskItem] { overdue + today + upcoming }

    private func apply(_ tasks: [TaskItem]) {
        applyPending(tasks.filter { $0.status == .pending })
        completedToday = tasks
            .filter { $0.status == .completed && Calendar.current.isDateInToday($0.modifiedAt) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func applyPending(_ tasks: [TaskItem]) {
        let sorted = tasks.sorted { lhs, rhs in
            if lhs.anchorDate != rhs.anchorDate { return lhs.anchorDate < rhs.anchorDate }
            return lhs.priority < rhs.priority
        }
        overdue = sorted.filter { $0.isOverdue }
        today = sorted.filter { !$0.isOverdue && isDueToday($0) }
        upcoming = sorted.filter { !$0.isOverdue && !isDueToday($0) }
        rebuildAgenda()
    }

    private func rebuildAgenda() {
        let taskEntries = today.map { AgendaEntry.task($0) }
        todayAgenda = (eventEntries + taskEntries).sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.sortStart != rhs.sortStart { return lhs.sortStart < rhs.sortStart }
            return lhs.sortTitle < rhs.sortTitle
        }
    }

    private func isDueToday(_ task: TaskItem) -> Bool {
        let calendar = Calendar.current
        switch task.body {
        case .habit:
            return !task.isHabitCompletedToday
        case .milestone(let target):
            return calendar.startOfDay(for: target) <= calendar.startOfDay(for: Date())
        case .task, .event:
            return calendar.isDateInToday(task.anchorDate)
        }
    }

    private static func mirrorKey(title: String, start: Date, isAllDay: Bool) -> String {
        isAllDay ? title + "|all-day" : title + "|" + String(start.timeIntervalSinceReferenceDate)
    }
}
