import Combine
import Foundation
import GeoCore

/// Grade do mês usada só pela aba Calendário (cópia privada dos helpers do
/// MonthGridView da Home: semana começa na segunda).
enum CalGrid {
    static var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal
    }

    static let weekdayLabels = ["seg", "ter", "qua", "qui", "sex", "sáb", "dom"]

    static func days(for month: Date) -> [Date] {
        let cal = calendar
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let weekday = cal.component(.weekday, from: startOfMonth)
        let offset = (weekday - cal.firstWeekday + 7) % 7
        let gridStart = cal.date(byAdding: .day, value: -offset, to: startOfMonth) ?? startOfMonth
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    /// Os sete dias da semana (segunda a domingo) que contêm `date`.
    static func week(containing date: Date) -> [Date] {
        let cal = calendar
        let start = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: start)
        let offset = (weekday - cal.firstWeekday + 7) % 7
        let monday = cal.date(byAdding: .day, value: -offset, to: start) ?? start
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
    }

    static func monthTitle(for month: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: month).lowercased()
    }

    /// "Terça, 16 de setembro" — sem o "-feira".
    static func dayTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE, d 'de' MMMM"
        let raw = formatter.string(from: date).replacingOccurrences(of: "-feira", with: "")
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    static func time(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// O que um dia da grade tem: tarefa/evento, treino, dinheiro.
enum CalendarMarker: String, Hashable, Identifiable {
    case task
    case training
    case money

    var id: String { rawValue }
}

/// Uma linha da agenda do dia: tarefa do hub ou evento do EventKit.
enum CalendarAgendaItem: Identifiable {
    case task(TaskItem)
    case event(CalendarEventItem)

    var id: String {
        switch self {
        case .task(let task): return "task-" + task.id
        case .event(let event): return "event-" + event.id
        }
    }

    var title: String {
        switch self {
        case .task(let task): return task.title
        case .event(let event): return event.title
        }
    }

    var start: Date {
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

    var isDone: Bool {
        switch self {
        case .task(let task): return task.status == .completed
        case .event: return false
        }
    }

    var timeLabel: String? {
        guard !isAllDay else { return nil }
        return CalGrid.time(for: start)
    }
}

/// Lançamento do dia: o que já aconteceu ou a projeção de um recorrente.
struct CalendarMoneyItem: Identifiable {
    var id: String
    var category: String
    var amount: Decimal
    var kind: MoneyKind
    var projected: Bool

    var amountText: String {
        let value = MoneyFormat.brl(amount)
        return kind == .expense ? "−" + value : value
    }
}

@MainActor
final class CalendarViewModel: ObservableObject {
    enum Mode {
        case month
        case week
    }

    @Published var selectedDate = Date() {
        didSet {
            guard !CalGrid.calendar.isDate(oldValue, inSameDayAs: selectedDate) else { return }
            syncDisplayedMonth()
            Task { await loadTraining(around: selectedDate) }
        }
    }

    @Published private(set) var displayedMonth = Date()
    @Published var mode: Mode = .month
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var moneyEntries: [MoneyEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// Planos de treino já buscados, por semana ISO ("2026-W38").
    @Published private(set) var plans: [String: WeeklyPlan] = [:]
    @Published private(set) var trainingLogs: [VitalsLog] = []
    /// Treino de hoje quando o hub só tem o protocolo legado (sem plano semanal).
    @Published private(set) var legacyToday: VitalsSession?

    private var eventsByDay: [Date: [CalendarEventItem]] = [:]
    private var loadedWeeks = Set<String>()

    private let tasksRepository: BridgeTasksRepository
    private let trainingRepository: BridgeTrainingRepository
    private let health: HealthViewModel
    private let eventKit: EventKitService
    private let clock = TrainingClock()
    private var cancellables = Set<AnyCancellable>()

    init(
        tasksRepository: BridgeTasksRepository = BridgeTasksRepository(),
        trainingRepository: BridgeTrainingRepository = BridgeTrainingRepository(),
        health: HealthViewModel? = nil,
        eventKit: EventKitService? = nil
    ) {
        self.tasksRepository = tasksRepository
        self.trainingRepository = trainingRepository
        self.health = health ?? HealthViewModel()
        self.eventKit = eventKit ?? .shared
        displayedMonth = selectedDate
        if let cached = tasksRepository.cached() {
            tasks = cached.tasks
        }
        MoneyStore.shared.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] entries in self?.moneyEntries = entries }
            .store(in: &cancellables)
        self.eventKit.$changeToken
            .dropFirst()
            .sink { [weak self] _ in self?.reloadEvents() }
            .store(in: &cancellables)
    }

    // MARK: - Carregamento

    func load() async {
        isLoading = true
        defer { isLoading = false }
        async let tasksRequest: Void = loadTasks()
        async let trainingRequest: Void = loadHealth()
        _ = await (tasksRequest, trainingRequest)
        reloadEvents()
        await loadTraining(around: selectedDate)
    }

    private func loadTasks() async {
        do {
            tasks = try await tasksRepository.list()
            errorMessage = nil
        } catch {
            // Offline: mantém o que veio do cache.
            if tasks.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func loadHealth() async {
        await health.reload()
        trainingLogs = health.logs
        legacyToday = health.isPlanPrimary ? nil : health.todaySession
        if let plan = health.plan {
            plans[plan.week] = plan
            loadedWeeks.insert(plan.week)
        }
    }

    /// Busca o plano da semana do mês exibido que ainda não veio.
    func loadTraining(around date: Date) async {
        let weeks = Set(visibleDates(for: date).map { clock.weekKey(for: $0) })
        for week in weeks.sorted() where !loadedWeeks.contains(week) {
            loadedWeeks.insert(week)
            if let plan = try? await trainingRepository.fetchPlan(week: week) {
                plans[plan.week] = plan
            }
        }
    }

    private func visibleDates(for date: Date) -> [Date] {
        mode == .week ? CalGrid.week(containing: date) : CalGrid.days(for: displayedMonth)
    }

    private func reloadEvents() {
        let cal = CalGrid.calendar
        let days = CalGrid.days(for: displayedMonth)
        guard let first = days.first, let last = days.last,
              let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last))
        else { return }
        var result: [Date: [CalendarEventItem]] = [:]
        for event in eventKit.events(in: DateInterval(start: cal.startOfDay(for: first), end: end)) {
            result[cal.startOfDay(for: event.start), default: []].append(event)
        }
        eventsByDay = result
    }

    var isCalendarAuthorized: Bool { eventKit.isCalendarAuthorized }

    func requestCalendarAccess() async {
        await eventKit.requestAccess()
        reloadEvents()
    }

    // MARK: - Navegação

    func shiftPeriod(by steps: Int) {
        let cal = CalGrid.calendar
        switch mode {
        case .month:
            guard let next = cal.date(byAdding: .month, value: steps, to: displayedMonth) else { return }
            displayedMonth = next
            reloadEvents()
            Task { await loadTraining(around: next) }
        case .week:
            guard let next = cal.date(byAdding: .weekOfYear, value: steps, to: selectedDate) else { return }
            selectedDate = next
        }
    }

    func goToToday() {
        let today = Date()
        selectedDate = today
        displayedMonth = today
        reloadEvents()
        Task { await loadTraining(around: today) }
    }

    func select(_ date: Date) {
        selectedDate = date
    }

    private func syncDisplayedMonth() {
        let cal = CalGrid.calendar
        guard !cal.isDate(displayedMonth, equalTo: selectedDate, toGranularity: .month) else { return }
        displayedMonth = selectedDate
        reloadEvents()
    }

    var title: String { CalGrid.monthTitle(for: mode == .week ? selectedDate : displayedMonth) }

    var visibleDays: [Date] {
        mode == .week ? CalGrid.week(containing: selectedDate) : CalGrid.days(for: displayedMonth)
    }

    var dayTitle: String { CalGrid.dayTitle(for: selectedDate) }

    // MARK: - Marcadores

    func markers(for date: Date) -> [CalendarMarker] {
        var result: [CalendarMarker] = []
        if !agenda(for: date).isEmpty { result.append(.task) }
        if let entry = training(for: date), !entry.rest { result.append(.training) }
        if !moneyItems(for: date).isEmpty { result.append(.money) }
        return result
    }

    // MARK: - Tarefas e eventos

    func agenda(for date: Date) -> [CalendarAgendaItem] {
        let cal = CalGrid.calendar
        let dayTasks = tasks
            .filter { cal.isDate($0.anchorDate, inSameDayAs: date) }
            .map { CalendarAgendaItem.task($0) }
        let events = (eventsByDay[cal.startOfDay(for: date)] ?? []).map { CalendarAgendaItem.event($0) }
        return (dayTasks + events).sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.title < rhs.title
        }
    }

    func toggle(_ task: TaskItem) {
        let completing = task.status == .pending
        var updated = task
        updated.status = completing ? .completed : .pending
        updated.modifiedAt = Date()
        replace(updated)
        Task {
            do {
                if completing {
                    try await tasksRepository.completeTask(id: task.id)
                } else {
                    try await tasksRepository.reopenTask(id: task.id)
                }
                errorMessage = nil
            } catch {
                replace(task)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func replace(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
    }

    // MARK: - Treino

    func training(for date: Date) -> TrainingWeekEntry? {
        let week = clock.weekKey(for: date)
        let day = clock.dayKey(for: date)
        guard let plan = plans[week] else { return nil }
        return TrainingWeekList.entries(
            plan: plan,
            sessions: [],
            todayIndex: nil,
            logs: trainingLogs,
            today: clock.dayKey(for: Date())
        ).first { $0.dayKey == day }
    }

    /// Sem plano semanal o hub só sabe o treino de hoje (protocolo legado gira
    /// a partir da âncora), então outros dias ficam sem linha de treino.
    func legacySession(for date: Date) -> VitalsSession? {
        guard CalGrid.calendar.isDateInToday(date) else { return nil }
        return legacyToday
    }

    // MARK: - Financeiro

    func moneyItems(for date: Date) -> [CalendarMoneyItem] {
        let cal = CalGrid.calendar
        let realized = moneyEntries
            .filter { cal.isDate($0.date, inSameDayAs: date) }
            .map {
                CalendarMoneyItem(
                    id: $0.id.uuidString,
                    category: $0.category,
                    amount: $0.amount,
                    kind: $0.kind,
                    projected: false
                )
            }
        return realized + projections(for: date)
    }

    /// Todo recorrente se repete no mesmo dia dos meses seguintes (no último dia
    /// quando o mês é mais curto), só para o futuro e só se ainda não houver um
    /// lançamento igual naquele mês.
    private func projections(for date: Date) -> [CalendarMoneyItem] {
        let cal = CalGrid.calendar
        let day = cal.startOfDay(for: date)
        guard day >= cal.startOfDay(for: Date()) else { return [] }

        return moneyEntries.compactMap { entry -> CalendarMoneyItem? in
            guard entry.recurring else { return nil }
            guard cal.compare(entry.date, to: day, toGranularity: .month) == .orderedAscending else { return nil }
            guard let projected = Self.projectedDate(of: entry.date, into: day, calendar: cal),
                  cal.isDate(projected, inSameDayAs: day) else { return nil }
            let alreadyPaid = moneyEntries.contains { other in
                other.id != entry.id
                    && cal.isDate(other.date, equalTo: day, toGranularity: .month)
                    && other.category == entry.category
                    && other.amount == entry.amount
                    && other.kind == entry.kind
            }
            guard !alreadyPaid else { return nil }
            return CalendarMoneyItem(
                id: "recurring-" + entry.id.uuidString + "-" + String(day.timeIntervalSinceReferenceDate),
                category: entry.category,
                amount: entry.amount,
                kind: entry.kind,
                projected: true
            )
        }
    }

    static func projectedDate(of origin: Date, into month: Date, calendar: Calendar) -> Date? {
        let originDay = calendar.component(.day, from: origin)
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let range = calendar.range(of: .day, in: .month, for: monthStart)
        else { return nil }
        let day = min(originDay, range.count)
        return calendar.date(byAdding: .day, value: day - 1, to: monthStart)
    }
}
