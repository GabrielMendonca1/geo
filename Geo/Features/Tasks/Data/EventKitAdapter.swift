import Combine
import EventKit
import Foundation
import GeoCore

@MainActor
final class EventKitAdapter: ObservableObject {
    static let shared = EventKitAdapter()

    let store = EKEventStore()

    @Published private(set) var changeToken = 0

    private var recentWrites: [String: Date] = [:]
    private let writeGracePeriod: TimeInterval = 2.0

    private init() {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.changeToken &+= 1 }
        }
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    var isAuthorized: Bool {
        authorizationStatus == .fullAccess
    }

    @discardableResult
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    func events(in interval: DateInterval, calendars: [EKCalendar]? = nil) -> [EKEvent] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: calendars
        )
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    func event(withIdentifier id: String) -> EKEvent? {
        store.event(withIdentifier: id)
    }

    @discardableResult
    func create(
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        notes: String? = nil,
        calendar: EKCalendar? = nil
    ) throws -> String {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.notes = notes
        event.calendar = calendar ?? store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        stampWrite(event.eventIdentifier)
        return event.eventIdentifier
    }

    @discardableResult
    func update(
        id: String,
        title: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        isAllDay: Bool? = nil,
        notes: String? = nil
    ) throws -> Bool {
        guard let event = store.event(withIdentifier: id) else { return false }
        if let title { event.title = title }
        if let start { event.startDate = start }
        if let end { event.endDate = end }
        if let isAllDay { event.isAllDay = isAllDay }
        if let notes { event.notes = notes }
        try store.save(event, span: .thisEvent, commit: true)
        stampWrite(id)
        return true
    }

    func delete(id: String) throws {
        guard let event = store.event(withIdentifier: id) else { return }
        stampWrite(id)
        try store.remove(event, span: .thisEvent, commit: true)
    }

    func wasRecentlyWritten(_ id: String) -> Bool {
        pruneWrites()
        guard let timestamp = recentWrites[id] else { return false }
        return Date().timeIntervalSince(timestamp) < writeGracePeriod
    }

    private func stampWrite(_ id: String) {
        recentWrites[id] = Date()
    }

    private func pruneWrites() {
        let cutoff = Date().addingTimeInterval(-writeGracePeriod * 2)
        recentWrites = recentWrites.filter { $0.value > cutoff }
    }

    @discardableResult
    func mirror(task: TaskItem) -> String? {
        guard isAuthorized else { return task.externalEKEventID }
        let plan = Self.mirrorPlan(for: task)
        let calendar = poolCalendar(forID: task.id)
        do {
            if let id = task.externalEKEventID, let existing = store.event(withIdentifier: id) {
                if plan.recurrenceRules.isEmpty {
                    configure(existing, with: plan, calendar: calendar)
                    try store.save(existing, span: .thisEvent, commit: true)
                    stampWrite(id)
                    return id
                }
                // Recorrente: editar com .futureEvents SPLITA a série (WWDC 2010 s.136). Se já
                // casa, no-op; senão remove a série inteira e recria — único jeito dup-proof.
                if Self.recurringEvent(existing, matches: plan) { return id }
                stampWrite(id)
                try? store.remove(existing, span: .futureEvents, commit: false)
                return try createEvent(plan, calendar: calendar)
            }
            return try createEvent(plan, calendar: calendar)
        } catch {
            return task.externalEKEventID
        }
    }

    private func createEvent(_ plan: EventMirrorPlan, calendar: EKCalendar) throws -> String {
        let event = EKEvent(eventStore: store)
        configure(event, with: plan, calendar: calendar)
        let span: EKSpan = plan.recurrenceRules.isEmpty ? .thisEvent : .futureEvents
        try store.save(event, span: span, commit: true)
        stampWrite(event.eventIdentifier)
        return event.eventIdentifier
    }

    private static func recurringEvent(_ event: EKEvent, matches plan: EventMirrorPlan) -> Bool {
        guard event.isAllDay == plan.isAllDay,
              event.title == plan.title else { return false }
        let cal = Calendar.current
        guard cal.dateComponents([.hour, .minute], from: event.startDate) ==
              cal.dateComponents([.hour, .minute], from: plan.start) else { return false }
        let evRule = event.recurrenceRules?.first
        let planRule = plan.recurrenceRules.first
        return evRule?.frequency == planRule?.frequency && evRule?.interval == planRule?.interval
    }

    func removeMirror(for task: TaskItem) {
        guard isAuthorized, let id = task.externalEKEventID else { return }
        guard let event = store.event(withIdentifier: id) else { return }
        stampWrite(id)
        let span: EKSpan = (event.recurrenceRules?.isEmpty == false) ? .futureEvents : .thisEvent
        try? store.remove(event, span: span, commit: true)
    }

    private func configure(_ event: EKEvent, with plan: EventMirrorPlan, calendar: EKCalendar) {
        event.title = plan.title
        event.isAllDay = plan.isAllDay
        event.startDate = plan.start
        event.endDate = plan.end
        // Identidade fica só no externalEKEventID guardado na task (.json), NÃO no evento —
        // url é visível no Calendar do macOS e notes no iOS; ambos limpos.
        event.url = nil
        event.notes = nil
        event.calendar = calendar
        for existing in event.recurrenceRules ?? [] {
            event.removeRecurrenceRule(existing)
        }
        for rule in plan.recurrenceRules {
            event.addRecurrenceRule(rule)
        }
    }

    // Cor é por-calendário no EventKit (não há cor por-evento). Pra dar cor "aleatória" por
    // evento sem padrão de tipo: pool de N calendários coloridos; cada task cai num deles por um
    // hash ESTÁVEL do id (djb2 — hashValue nativo é randomizado por processo, não serve).
    private static let poolColors: [CGColor] = [
        CGColor(srgbRed: 1.00, green: 0.231, blue: 0.188, alpha: 1), // vermelho
        CGColor(srgbRed: 1.00, green: 0.584, blue: 0.00, alpha: 1),  // laranja
        CGColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1), // verde
        CGColor(srgbRed: 0.188, green: 0.690, blue: 0.780, alpha: 1), // teal
        CGColor(srgbRed: 0.00, green: 0.478, blue: 1.00, alpha: 1),  // azul
        CGColor(srgbRed: 0.686, green: 0.322, blue: 0.871, alpha: 1), // roxo
    ]

    private static func poolIndex(for id: String) -> Int {
        var h: UInt64 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % UInt64(poolColors.count))
    }

    // iCloud (.calDAV) sincroniza p/ iPhone; .local ("On My Mac") NÃO. Preferir iCloud sempre.
    private var preferredEventSource: EKSource? {
        store.sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" })
            ?? store.defaultCalendarForNewEvents?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first
    }

    // Cache in-memory por índice: store.calendars() pode não refletir um saveCalendar recém-commitado
    // (lista cacheada), o que fazia 2 mirrors concorrentes criarem o mesmo "Geo · N" 2×.
    private var poolCalendarCache: [Int: EKCalendar] = [:]

    func poolCalendar(forID id: String) -> EKCalendar {
        let index = Self.poolIndex(for: id)
        if let cached = poolCalendarCache[index] { return cached }
        let title = "Geo · \(index + 1)"
        if let existing = store.calendars(for: .event).first(where: { $0.title == title }) {
            poolCalendarCache[index] = existing
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = title
        cal.cgColor = Self.poolColors[index]
        cal.source = preferredEventSource
        do {
            try store.saveCalendar(cal, commit: true)
            poolCalendarCache[index] = cal
            return cal
        } catch {
            return geoCalendar()
        }
    }

    func geoCalendar() -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: { $0.title == "Geo" }) {
            return existing
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Geo"
        calendar.source = preferredEventSource
        do {
            try store.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            return store.defaultCalendarForNewEvents
                ?? store.calendars(for: .event).first
                ?? calendar
        }
    }
}

struct EventMirrorPlan {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var recurrenceRules: [EKRecurrenceRule]
}

extension EventKitAdapter {
    static func mirrorPlan(for task: TaskItem) -> EventMirrorPlan {
        let calendar = Calendar.current
        let title = task.status == .completed ? "✓ \(task.title)" : task.title

        let allDay = task.resolvedIsAllDay
        switch task.body {
        case .event(let start, let end, _):
            if allDay {
                let dayStart = calendar.startOfDay(for: start)
                return EventMirrorPlan(
                    title: title, start: dayStart, end: dayStart,
                    isAllDay: true, recurrenceRules: []
                )
            }
            return EventMirrorPlan(
                title: title, start: start, end: max(end, start),
                isAllDay: false, recurrenceRules: []
            )
        case .habit(let rule, let timeOfDay, _):
            return Self.plan(
                forAnchor: timeOfDay, title: title, calendar: calendar, isAllDay: allDay,
                recurrenceRules: rule.toEKRecurrenceRule().map { [$0] } ?? []
            )
        case .task(let due, _):
            return Self.plan(forAnchor: due, title: title, calendar: calendar, isAllDay: allDay)
        case .milestone(let target):
            return Self.plan(forAnchor: target, title: title, calendar: calendar, isAllDay: allDay)
        }
    }

    private static func plan(forAnchor anchor: Date, title: String, calendar: Calendar, isAllDay: Bool, recurrenceRules: [EKRecurrenceRule] = []) -> EventMirrorPlan {
        if isAllDay {
            let dayStart = calendar.startOfDay(for: anchor)
            // all-day: endDate é INCLUSIVO no EventKit (verificado macOS 26) — end no MESMO dia
            // renderiza 1 dia; end=+1dia renderiza 2 dias (a falsa "duplicata").
            return EventMirrorPlan(
                title: title, start: dayStart, end: dayStart,
                isAllDay: true, recurrenceRules: recurrenceRules
            )
        }
        return EventMirrorPlan(
            title: title, start: anchor, end: anchor.addingTimeInterval(3600),
            isAllDay: false, recurrenceRules: recurrenceRules
        )
    }
}

extension RecurrenceRule {
    func toEKRecurrenceRule() -> EKRecurrenceRule? {
        let end = endDate.map { EKRecurrenceEnd(end: $0) }

        func daysOfWeek(_ weekdays: [Int]?) -> [EKRecurrenceDayOfWeek]? {
            guard let weekdays, !weekdays.isEmpty else { return nil }
            let mapped = weekdays.compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } }
            return mapped.isEmpty ? nil : mapped
        }

        func rule(_ freq: EKRecurrenceFrequency, _ interval: Int, days: [EKRecurrenceDayOfWeek]? = nil) -> EKRecurrenceRule {
            EKRecurrenceRule(
                recurrenceWith: freq,
                interval: max(1, interval),
                daysOfTheWeek: days,
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: end
            )
        }

        switch type {
        case .never:
            return nil
        case .daily:
            return rule(.daily, 1)
        case .weekdays:
            let weekdays: [EKRecurrenceDayOfWeek] = [.monday, .tuesday, .wednesday, .thursday, .friday]
                .map { EKRecurrenceDayOfWeek($0) }
            return rule(.weekly, 1, days: weekdays)
        case .weekly:
            return rule(.weekly, 1, days: daysOfWeek(selectedWeekdays))
        case .biweekly:
            return rule(.weekly, 2, days: daysOfWeek(selectedWeekdays))
        case .monthly:
            return rule(.monthly, 1)
        case .yearly:
            return rule(.yearly, 1)
        case .custom:
            let interval = max(1, customInterval ?? 1)
            let freq: EKRecurrenceFrequency
            switch customFrequency ?? .daily {
            case .daily: freq = .daily
            case .weekly: freq = .weekly
            case .monthly: freq = .monthly
            case .yearly: freq = .yearly
            }
            return rule(freq, interval)
        }
    }
}
