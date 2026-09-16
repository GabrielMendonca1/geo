import Foundation
import GeoCore

/// Lista de tarefas da aba Tarefas. Carrega do bridge (GET /tasks) e faz as
/// mutações otimistas — a parte de repositório é a mesma do TodayViewModel,
/// duplicada aqui de propósito para esta aba ter estado próprio.
@MainActor
final class TasksViewModel: ObservableObject {
    @Published private(set) var pending: [TaskItem] = []
    @Published private(set) var completed: [TaskItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?

    private var allTasks: [TaskItem] = []
    private let repository: BridgeTasksRepository

    init(repository: BridgeTasksRepository = BridgeTasksRepository()) {
        self.repository = repository
        if let cached = repository.cached() {
            allTasks = cached.tasks
            rebuild()
        }
    }

    var isEmpty: Bool { pending.isEmpty && completed.isEmpty }

    func reload() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            allTasks = try await repository.list()
            errorMessage = nil
        } catch {
            guard allTasks.isEmpty else {
                errorMessage = nil
                return
            }
            errorMessage = error.localizedDescription
        }
        rebuild()
    }

    // MARK: - Mutações

    func complete(_ task: TaskItem) {
        guard task.status == .pending else { return }
        apply(status: .completed, to: task.id)
        Task {
            do {
                try await repository.completeTask(id: task.id)
                errorMessage = nil
            } catch {
                apply(status: .pending, to: task.id)
                errorMessage = error.localizedDescription
            }
        }
    }

    func reopen(_ task: TaskItem) {
        guard task.status == .completed else { return }
        apply(status: .pending, to: task.id)
        Task {
            do {
                try await repository.reopenTask(id: task.id)
                errorMessage = nil
            } catch {
                apply(status: .completed, to: task.id)
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(_ task: TaskItem) {
        allTasks.removeAll { $0.id == task.id }
        rebuild()
        Task {
            do {
                try await repository.delete(id: task.id)
                errorMessage = nil
            } catch {
                allTasks.append(task)
                rebuild()
                errorMessage = error.localizedDescription
            }
        }
    }

    func complete(ids: Set<String>) {
        for task in allTasks where ids.contains(task.id) && task.status == .pending {
            complete(task)
        }
    }

    func delete(ids: Set<String>) {
        for task in allTasks where ids.contains(task.id) {
            delete(task)
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
        allTasks.append(provisional)
        rebuild()
        Task {
            do {
                let created = try await repository.create(provisional)
                allTasks.removeAll { $0.id == provisional.id || $0.id == created.id }
                allTasks.append(created)
                errorMessage = nil
            } catch {
                allTasks.removeAll { $0.id == provisional.id }
                errorMessage = error.localizedDescription
            }
            rebuild()
        }
    }

    // MARK: - Mover data

    /// Move a tarefa para outro dia mantendo a hora original.
    func reschedule(_ task: TaskItem, to date: Date) {
        guard let updated = Self.rescheduled(task, to: date) else { return }
        let previous = task
        replace(updated)
        Task {
            do {
                try await repository.update(updated)
                errorMessage = nil
            } catch {
                replace(previous)
                errorMessage = error.localizedDescription
            }
        }
    }

    func reschedule(ids: Set<String>, to date: Date) {
        for task in allTasks where ids.contains(task.id) {
            reschedule(task, to: date)
        }
    }

    /// Troca só o dia do corpo da tarefa; hábitos ficam como estão.
    static func rescheduled(_ task: TaskItem, to day: Date) -> TaskItem? {
        var updated = task
        switch task.body {
        case .task(let due, let estimated):
            updated.body = .task(due: moveDay(of: due, to: day), estimatedMinutes: estimated)
        case .event(let start, let end, let externalID):
            let newStart = moveDay(of: start, to: day)
            let newEnd = newStart.addingTimeInterval(end.timeIntervalSince(start))
            updated.body = .event(start: newStart, end: newEnd, externalEKEventID: externalID)
        case .milestone(let target):
            updated.body = .milestone(target: moveDay(of: target, to: day))
        case .habit:
            return nil
        }
        updated.modifiedAt = Date()
        return updated
    }

    /// Mantém hora/minuto/segundo de `original` no dia de `day`.
    static func moveDay(of original: Date, to day: Date, calendar: Calendar = .current) -> Date {
        let time = calendar.dateComponents([.hour, .minute, .second], from: original)
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: time.second ?? 0,
            of: day
        ) ?? day
    }

    private func replace(_ task: TaskItem) {
        guard let index = allTasks.firstIndex(where: { $0.id == task.id }) else { return }
        allTasks[index] = task
        rebuild()
    }

    // MARK: - Ordenação

    private func apply(status: TaskStatus, to id: String) {
        guard let index = allTasks.firstIndex(where: { $0.id == id }) else { return }
        allTasks[index].status = status
        allTasks[index].modifiedAt = Date()
        rebuild()
    }

    private func rebuild() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        pending = allTasks
            .filter { $0.status == .pending }
            .sorted { lhs, rhs in
                let lb = Self.bucket(lhs, today: today, calendar: calendar)
                let rb = Self.bucket(rhs, today: today, calendar: calendar)
                if lb != rb { return lb < rb }
                if lb == 3 { return lhs.orderIndex < rhs.orderIndex }
                if lhs.anchorDate != rhs.anchorDate { return lhs.anchorDate < rhs.anchorDate }
                if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
                return lhs.title < rhs.title
            }

        completed = allTasks
            .filter { $0.status == .completed }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 0 atrasada · 1 hoje · 2 futura · 3 sem data
    private static func bucket(_ task: TaskItem, today: Date, calendar: Calendar) -> Int {
        guard let date = TasksDate.scheduled(task) else { return 3 }
        let day = calendar.startOfDay(for: date)
        if day < today { return 0 }
        if day == today { return 1 }
        return 2
    }
}

/// Datas exibidas na aba Tarefas.
enum TasksDate {
    /// Data agendada da tarefa (nil quando o tipo não carrega data útil).
    static func scheduled(_ task: TaskItem) -> Date? {
        switch task.body {
        case .task(let due, _): return due
        case .event(let start, _, _): return start
        case .habit(_, let timeOfDay, _): return timeOfDay
        case .milestone(let target): return target
        }
    }

    static func isOverdue(_ task: TaskItem) -> Bool {
        guard task.status == .pending, let date = scheduled(task) else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: date) < calendar.startOfDay(for: Date())
    }

    /// "Hoje", "Amanhã", "Seg 21".
    static func label(_ task: TaskItem) -> String? {
        guard let date = scheduled(task) else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Hoje" }
        if calendar.isDateInTomorrow(date) { return "Amanhã" }
        if calendar.isDateInYesterday(date) { return "Ontem" }
        return shortFormatter.string(from: date)
            .replacingOccurrences(of: ".", with: "")
            .capitalized
    }

    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEE d"
        return formatter
    }()
}
