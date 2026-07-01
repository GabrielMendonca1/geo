import Combine
import EventKit
import Foundation
import GeoCore

struct TodayRow: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date?
    let isAllDay: Bool
    let kind: TaskKind
    let isCompleted: Bool
    let reminderID: String?
    let calendarTitle: String?

    var timeLabel: String {
        if isAllDay { return "All-day" }
        let t = MobileDateFormatters.shortTime
        if let end, kind == .event {
            return "\(t.string(from: start))–\(t.string(from: end))"
        }
        return t.string(from: start)
    }
}

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var rows: [TodayRow] = []
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

    var isAuthorized: Bool { service.isCalendarAuthorized || service.isRemindersAuthorized }

    var dayTitle: String { "Today" }

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
        defer { isLoading = false }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var merged: [TodayRow] = []

        for event in service.events(in: dayInterval) {
            merged.append(
                TodayRow(
                    id: event.id,
                    title: event.title,
                    start: event.start,
                    end: event.end,
                    isAllDay: event.isAllDay,
                    kind: .event,
                    isCompleted: false,
                    reminderID: nil,
                    calendarTitle: event.calendarTitle
                )
            )
        }

        for reminder in await service.fetchReminders() {
            guard let due = reminder.dueDate, cal.isDate(due, inSameDayAs: today) else { continue }
            merged.append(
                TodayRow(
                    id: "rem-" + reminder.id,
                    title: reminder.title,
                    start: due,
                    end: nil,
                    isAllDay: false,
                    kind: reminder.kind,
                    isCompleted: reminder.isCompleted,
                    reminderID: reminder.id,
                    calendarTitle: reminder.calendarTitle
                )
            )
        }

        rows = merged.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.title < rhs.title
        }
    }

    func toggle(_ row: TodayRow) {
        guard let id = row.reminderID else { return }
        service.toggleCompleted(reminderID: id)
    }
}
