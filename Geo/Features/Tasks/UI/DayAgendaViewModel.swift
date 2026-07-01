import Combine
import GeoCore
import EventKit
import Foundation

struct AgendaRow: Identifiable, Hashable {
    enum Source: Hashable {
        case calendarEvent(String)
        case task(String)
        case event(String)
        case habit(String)
    }

    let id: String
    let source: Source
    let title: String
    let start: Date
    let end: Date?
    let isAllDay: Bool
    let isCompleted: Bool
    let calendarTitle: String?

    var kind: TaskKind {
        switch source {
        case .calendarEvent, .event: return .event
        case .task: return .task
        case .habit: return .habit
        }
    }

    var completableTaskId: String? {
        switch source {
        case .task(let id), .event(let id), .habit(let id): return id
        case .calendarEvent: return nil
        }
    }

    var calendarEventId: String? {
        if case .calendarEvent(let id) = source { return id }
        return nil
    }

    var timeLabel: String {
        if isAllDay { return "All-day" }
        let t = DateFormatters.shortTime
        if let end, kind == .event {
            return "\(t.string(from: start))–\(t.string(from: end))"
        }
        return t.string(from: start)
    }
}

@MainActor
final class DayAgendaViewModel: ObservableObject {
    @Published var selectedDay: Date
    @Published private(set) var rows: [AgendaRow] = []

    private let eventKit: EventKitAdapter
    private var cancellable: AnyCancellable?

    init(eventKit: EventKitAdapter = .shared) {
        self.eventKit = eventKit
        selectedDay = Calendar.current.startOfDay(for: Date())
        cancellable = eventKit.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var changeToken: Int { eventKit.changeToken }
    var isAuthorized: Bool { eventKit.isAuthorized }
    var authorizationStatus: EKAuthorizationStatus { eventKit.authorizationStatus }
    var isToday: Bool { Calendar.current.isDateInToday(selectedDay) }

    var dayTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(selectedDay) { return "Today" }
        if cal.isDateInTomorrow(selectedDay) { return "Tomorrow" }
        if cal.isDateInYesterday(selectedDay) { return "Yesterday" }
        return DateFormatters.mediumDate.string(from: selectedDay)
    }

    private var dayInterval: DateInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: selectedDay)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    func goToToday() { selectedDay = Calendar.current.startOfDay(for: Date()) }
    func goToPreviousDay() { shiftDay(-1) }
    func goToNextDay() { shiftDay(1) }

    private func shiftDay(_ offset: Int) {
        let cal = Calendar.current
        if let next = cal.date(byAdding: .day, value: offset, to: selectedDay) {
            selectedDay = cal.startOfDay(for: next)
        }
    }

    func requestAccess() async {
        _ = await eventKit.requestAccess()
        objectWillChange.send()
    }

    @discardableResult
    func createEvent(title: String, start: Date, end: Date, isAllDay: Bool) -> Bool {
        guard eventKit.isAuthorized else { return false }
        do {
            _ = try eventKit.create(title: title, start: start, end: end, isAllDay: isAllDay)
            return true
        } catch {
            return false
        }
    }

    func updateEvent(id: String, title: String, start: Date, end: Date, isAllDay: Bool) {
        try? eventKit.update(id: id, title: title, start: start, end: end, isAllDay: isAllDay)
    }

    func deleteEvent(id: String) {
        try? eventKit.delete(id: id)
    }

    func updateRows(for tasks: [TaskItem]) {
        rows = computeRows(for: tasks)
    }

    private func computeRows(for tasks: [TaskItem]) -> [AgendaRow] {
        let cal = Calendar.current
        var rows: [AgendaRow] = []

        for ek in eventKit.events(in: dayInterval) {
            let eid: String? = ek.eventIdentifier
            let resolvedId = eid ?? ek.calendarItemIdentifier
            let titleOpt: String? = ek.title
            let title = titleOpt.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Event"
            rows.append(
                AgendaRow(
                    id: "ek-" + resolvedId,
                    source: .calendarEvent(resolvedId),
                    title: title,
                    start: ek.startDate,
                    end: ek.endDate,
                    isAllDay: ek.isAllDay,
                    isCompleted: false,
                    calendarTitle: ek.calendar?.title
                )
            )
        }

        for task in tasks {
            switch task.body {
            case .task(let due, _):
                guard cal.isDate(due, inSameDayAs: selectedDay) else { continue }
                rows.append(
                    AgendaRow(
                        id: "task-" + task.id,
                        source: .task(task.id),
                        title: task.title,
                        start: due,
                        end: nil,
                        isAllDay: task.resolvedIsAllDay,
                        isCompleted: task.status == .completed,
                        calendarTitle: nil
                    )
                )
            case .event(let start, let end, _):
                guard cal.isDate(start, inSameDayAs: selectedDay) else { continue }
                rows.append(
                    AgendaRow(
                        id: "gevent-" + task.id,
                        source: .event(task.id),
                        title: task.title,
                        start: start,
                        end: end,
                        isAllDay: task.resolvedIsAllDay,
                        isCompleted: task.status == .completed,
                        calendarTitle: nil
                    )
                )
            case .habit(let rule, let timeOfDay, let occurrences):
                guard habitOccurs(rule, anchor: timeOfDay, on: selectedDay, calendar: cal) else { continue }
                let occurredAt = cal.date(
                    bySettingHour: cal.component(.hour, from: timeOfDay),
                    minute: cal.component(.minute, from: timeOfDay),
                    second: 0,
                    of: selectedDay
                ) ?? selectedDay
                let done = occurrences.contains { cal.isDate($0, inSameDayAs: selectedDay) }
                rows.append(
                    AgendaRow(
                        id: "habit-" + task.id,
                        source: .habit(task.id),
                        title: task.title,
                        start: occurredAt,
                        end: nil,
                        isAllDay: task.resolvedIsAllDay,
                        isCompleted: done,
                        calendarTitle: nil
                    )
                )
            case .milestone:
                continue
            }
        }

        return rows.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.title < rhs.title
        }
    }

    private func habitOccurs(_ rule: RecurrenceRule, anchor: Date, on day: Date, calendar: Calendar) -> Bool {
        let target = calendar.startOfDay(for: day)
        let start = calendar.startOfDay(for: anchor)
        if target < start { return false }
        if let end = rule.endDate, target > calendar.startOfDay(for: end) { return false }

        switch rule.type {
        case .never:
            return target == start
        case .daily:
            return true
        case .weekdays:
            return !calendar.isDateInWeekend(target)
        case .weekly:
            return weeklyMatch(start: start, target: target, interval: 1, selected: rule.selectedWeekdays, calendar: calendar)
        case .biweekly:
            return weeklyMatch(start: start, target: target, interval: 2, selected: rule.selectedWeekdays, calendar: calendar)
        case .monthly:
            return calendar.component(.day, from: target) == calendar.component(.day, from: start)
        case .yearly:
            return calendar.component(.day, from: target) == calendar.component(.day, from: start)
                && calendar.component(.month, from: target) == calendar.component(.month, from: start)
        case .custom:
            let interval = max(1, rule.customInterval ?? 1)
            switch rule.customFrequency ?? .daily {
            case .daily:
                let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
                return days % interval == 0
            case .weekly:
                return weeklyMatch(start: start, target: target, interval: interval, selected: rule.selectedWeekdays, calendar: calendar)
            case .monthly:
                let months = calendar.dateComponents([.month], from: start, to: target).month ?? 0
                return months % interval == 0
                    && calendar.component(.day, from: target) == calendar.component(.day, from: start)
            case .yearly:
                let years = calendar.dateComponents([.year], from: start, to: target).year ?? 0
                return years % interval == 0
                    && calendar.component(.day, from: target) == calendar.component(.day, from: start)
                    && calendar.component(.month, from: target) == calendar.component(.month, from: start)
            }
        }
    }

    private func weeklyMatch(start: Date, target: Date, interval: Int, selected: [Int]?, calendar: Calendar) -> Bool {
        let weekAligned: Bool
        if interval <= 1 {
            weekAligned = true
        } else if let startWeek = calendar.dateInterval(of: .weekOfYear, for: start)?.start,
                  let targetWeek = calendar.dateInterval(of: .weekOfYear, for: target)?.start {
            let weeks = (calendar.dateComponents([.day], from: startWeek, to: targetWeek).day ?? 0) / 7
            weekAligned = weeks % interval == 0
        } else {
            weekAligned = true
        }

        guard weekAligned else { return false }

        if let selected, !selected.isEmpty {
            return selected.contains(calendar.component(.weekday, from: target))
        }
        return calendar.component(.weekday, from: target) == calendar.component(.weekday, from: start)
    }
}
