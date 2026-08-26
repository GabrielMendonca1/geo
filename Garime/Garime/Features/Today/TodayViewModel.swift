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
    @Published var selectedDate = Date() {
        didSet {
            guard !Calendar.current.isDate(oldValue, inSameDayAs: selectedDate) else { return }
            rebuildForSelectedDate()
            computeHasItemsByDate()
        }
    }
    @Published private(set) var displayedMonth = Date()
    @Published private(set) var overdue: [TaskItem] = []
    @Published private(set) var todayAgenda: [AgendaEntry] = []
    @Published private(set) var upcoming: [TaskItem] = []
    @Published private(set) var completedToday: [TaskItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isOffline = false
    @Published private(set) var cacheDate: Date?
    @Published private(set) var hasItemsByDate: [Date: Bool] = [:]
    @Published private(set) var calendarSyncError: String?

    private var allTasks: [TaskItem] = []
    private var mirrorTasks: [TaskItem] = []
    private var today: [TaskItem] = []
    private var eventEntries: [AgendaEntry] = []

    private let service: EventKitService
    private let repository: BridgeTasksRepository
    private var cancellable: AnyCancellable?

    init(service: EventKitService? = nil, repository: BridgeTasksRepository = BridgeTasksRepository()) {
        self.service = service ?? .shared
        self.repository = repository
        self.selectedDate = Date()
        if let cached = self.repository.cached() {
            allTasks = cached.tasks
            mirrorTasks = cached.tasks
            cacheDate = cached.fetchedAt
            computeHasItemsByDate()
            rebuildForSelectedDate()
        }
        cancellable = self.service.$changeToken
            .dropFirst()
            .sink { [weak self] _ in
                Task { await self?.reload() }
            }
    }

    var isAuthorized: Bool { service.isCalendarAuthorized }

    var dayTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "d 'de' MMMM"
        return formatter.string(from: selectedDate)
    }

    var offlineMessage: String? {
        guard isOffline else { return nil }
        guard let cacheDate, !allTasks.isEmpty else { return "hub offline" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "HH:mm"
        return "hub offline · dados de " + formatter.string(from: cacheDate)
    }

    var isEmpty: Bool {
        overdue.isEmpty && todayAgenda.isEmpty && upcoming.isEmpty && completedToday.isEmpty
    }

    private func dayInterval(for date: Date) -> DateInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
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

        do {
            let tasks = try await repository.list()
            errorMessage = nil
            isOffline = false
            cacheDate = Date()
            mirrorTasks = tasks
            syncMirror(with: mirrorTasks)
            guard tasks != allTasks else { return }
            allTasks = tasks
        } catch {
            isOffline = true
            errorMessage = nil
            guard allTasks.isEmpty else { return }
        }
        computeHasItemsByDate()
        rebuildForSelectedDate()
    }

    func complete(_ task: TaskItem) {
        var done = task
        done.status = .completed
        done.modifiedAt = Date()
        let pendingNow = pending.filter { $0.id != task.id }
        updateAllTasks { _ in pendingNow }
        completedToday.insert(done, at: 0)
        mirrorUpsert(done)
        Task {
            do {
                try await repository.completeTask(id: task.id)
                errorMessage = nil
            } catch {
                completedToday.removeAll { $0.id == task.id }
                let pendingNow = pending.filter { $0.id != task.id } + [task]
                updateAllTasks { _ in pendingNow }
                mirrorUpsert(task)
                errorMessage = error.localizedDescription
            }
        }
    }

    func reopen(_ task: TaskItem) {
        var reopened = task
        reopened.status = .pending
        reopened.modifiedAt = Date()
        completedToday.removeAll { $0.id == task.id }
        let pendingNow = pending.filter { $0.id != task.id } + [reopened]
        updateAllTasks { _ in pendingNow }
        mirrorUpsert(reopened)
        Task {
            do {
                try await repository.reopenTask(id: task.id)
                errorMessage = nil
            } catch {
                let pendingNow = pending.filter { $0.id != task.id }
                updateAllTasks { _ in pendingNow }
                completedToday.removeAll { $0.id == task.id }
                completedToday.insert(task, at: 0)
                mirrorUpsert(task)
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(_ task: TaskItem) {
        let wasCompleted = task.status == .completed
        let pendingNow = pending.filter { $0.id != task.id }
        updateAllTasks { _ in pendingNow }
        completedToday.removeAll { $0.id == task.id }
        mirrorRemove(id: task.id)
        Task {
            do {
                try await repository.delete(id: task.id)
                errorMessage = nil
            } catch {
                if wasCompleted {
                    completedToday.removeAll { $0.id == task.id }
                    completedToday.insert(task, at: 0)
                } else {
                    let pendingNow = pending.filter { $0.id != task.id } + [task]
                    updateAllTasks { _ in pendingNow }
                }
                mirrorUpsert(task)
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
        let pendingNow = pending + [provisional]
        updateAllTasks { _ in pendingNow }
        Task {
            do {
                let created = try await repository.create(provisional)
                let pendingNow = pending.filter { $0.id != provisional.id && $0.id != created.id } + [created]
                updateAllTasks { _ in pendingNow }
                mirrorTasks.removeAll { $0.id == provisional.id || $0.id == created.id }
                mirrorUpsert(created)
                errorMessage = nil
            } catch {
                let pendingNow = pending.filter { $0.id != provisional.id }
                updateAllTasks { _ in pendingNow }
                errorMessage = error.localizedDescription
            }
        }
    }

    private var pending: [TaskItem] { overdue + today + upcoming }

    private func updateAllTasks(_ transform: ([TaskItem]) -> [TaskItem]) {
        allTasks = transform(allTasks)
        rebuildForSelectedDate()
    }

    private func mirrorUpsert(_ task: TaskItem) {
        if let index = mirrorTasks.firstIndex(where: { $0.id == task.id }) {
            mirrorTasks[index] = task
        } else {
            mirrorTasks.append(task)
        }
        syncMirror(with: mirrorTasks)
    }

    private func mirrorRemove(id: String) {
        mirrorTasks.removeAll { $0.id == id }
        syncMirror(with: mirrorTasks)
    }

    private func syncMirror(with tasks: [TaskItem]) {
        service.syncMirror(tasks: tasks)
        calendarSyncError = service.mirrorErrorMessage
    }

    func shiftDisplayedMonth(by months: Int) {
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .month, value: months, to: displayedMonth) else { return }
        displayedMonth = next
        computeHasItemsByDate()
    }

    func syncDisplayedMonth(to date: Date) {
        let cal = Calendar.current
        guard !cal.isDate(displayedMonth, equalTo: date, toGranularity: .month) else { return }
        displayedMonth = date
        computeHasItemsByDate()
    }

    private func markedDates() -> [Date] {
        let cal = Calendar.current
        var dates = Set<Date>()
        for anchor in [Date(), selectedDate] {
            guard let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)) else { continue }
            for i in 0..<7 {
                if let date = cal.date(byAdding: .day, value: i, to: startOfWeek) {
                    dates.insert(cal.startOfDay(for: date))
                }
            }
        }
        for date in MonthGrid.days(for: displayedMonth) {
            dates.insert(cal.startOfDay(for: date))
        }
        return dates.sorted()
    }

    private func computeHasItemsByDate() {
        let cal = Calendar.current
        let dates = markedDates()
        guard let first = dates.first, let last = dates.last,
              let spanEnd = cal.date(byAdding: .day, value: 1, to: last)
        else {
            hasItemsByDate = [:]
            return
        }

        var eventDays = Set<Date>()
        for event in service.events(in: DateInterval(start: first, end: spanEnd)) {
            eventDays.insert(cal.startOfDay(for: event.start))
        }

        var result: [Date: Bool] = [:]
        for date in dates {
            let hasTask = allTasks.contains { task in
                guard task.status == .pending else { return false }
                switch task.body {
                case .habit:
                    return !task.isHabitCompletedToday && cal.isDate(task.anchorDate, inSameDayAs: date)
                case .task, .event, .milestone:
                    return cal.isDate(task.anchorDate, inSameDayAs: date)
                }
            }
            result[date] = hasTask || eventDays.contains(date)
        }
        hasItemsByDate = result
    }

    private func rebuildForSelectedDate() {
        let cal = Calendar.current
        let selectedInterval = dayInterval(for: selectedDate)
        let selectedTasks = allTasks.filter { $0.status == .pending }

        var mirroredKeys = Set<String>()
        for task in selectedTasks {
            guard case .task(let due, _) = task.body,
                  cal.isDateInToday(due) else { continue }
            if task.externalEKEventID != nil {
                mirroredKeys.insert(Self.mirrorKey(title: task.title, start: due, isAllDay: task.resolvedIsAllDay))
            }
        }

        eventEntries = service.events(in: selectedInterval)
            .filter { !mirroredKeys.contains(Self.mirrorKey(title: $0.title, start: $0.start, isAllDay: $0.isAllDay)) }
            .map { AgendaEntry.event($0) }

        let sorted = selectedTasks.sorted { lhs, rhs in
            if lhs.anchorDate != rhs.anchorDate { return lhs.anchorDate < rhs.anchorDate }
            return lhs.priority < rhs.priority
        }

        let todayStr = cal.startOfDay(for: Date())
        let selectedStr = cal.startOfDay(for: selectedDate)
        let isSelectedToday = todayStr == selectedStr

        overdue = isSelectedToday ? sorted.filter { $0.isOverdue } : []
        today = sorted.filter { !$0.isOverdue && isDueDate($0, selectedDate) }
        upcoming = sorted.filter { !$0.isOverdue && !isDueDate($0, selectedDate) }

        let taskEntries = today.map { AgendaEntry.task($0) }
        todayAgenda = (eventEntries + taskEntries).sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.sortStart != rhs.sortStart { return lhs.sortStart < rhs.sortStart }
            return lhs.sortTitle < rhs.sortTitle
        }

        completedToday = allTasks
            .filter { $0.status == .completed && cal.isDate($0.modifiedAt, inSameDayAs: selectedDate) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func isDueDate(_ task: TaskItem, _ date: Date) -> Bool {
        let calendar = Calendar.current
        switch task.body {
        case .habit:
            return !task.isHabitCompletedToday && calendar.isDate(task.anchorDate, inSameDayAs: date)
        case .milestone(let target):
            return calendar.startOfDay(for: target) <= calendar.startOfDay(for: date)
        case .task, .event:
            return calendar.isDate(task.anchorDate, inSameDayAs: date)
        }
    }

    private static func mirrorKey(title: String, start: Date, isAllDay: Bool) -> String {
        isAllDay ? title + "|all-day" : title + "|" + String(start.timeIntervalSinceReferenceDate)
    }
}
