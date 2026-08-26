import EventKit
import Foundation
import GeoCore

struct GarimeCalendarMirrorReport: Equatable {
    var created = 0
    var updated = 0
    var deleted = 0
    var skipped = 0
    var failureMessage: String?

    var isEmpty: Bool { created == 0 && updated == 0 && deleted == 0 && skipped == 0 }
}

enum GarimeCalendarMirrorError: LocalizedError {
    case notAuthorized
    case noWritableSource

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "sem acesso total ao calendário para espelhar o garime"
        case .noWritableSource:
            return "nenhuma conta de calendário gravável para criar \"" + CalendarMirror.calendarTitle + "\""
        }
    }
}

@MainActor
final class GarimeCalendarMirrorService {
    static let pastWindowDays = 30
    static let futureWindowDays = 400
    static let boundaryMarginDays = 1
    static let maxRepeatedPlans = 3
    static let retryCooldown: TimeInterval = 60

    private let store: EKEventStore
    private let defaults: UserDefaults
    private let storageKey = "garime.calendarMirror.calendarIdentifier"
    private var cachedCalendarIdentifier: String?
    private var lastPlanSignature: String?
    private var repeatedPlanCount = 0
    private var lastPlanAttempt: Date?

    init(store: EKEventStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.cachedCalendarIdentifier = defaults.string(forKey: storageKey)
    }

    var calendarIdentifier: String? { existingCalendar()?.calendarIdentifier }

    @discardableResult
    func sync(tasks: [TaskItem], now: Date = Date()) throws -> GarimeCalendarMirrorReport {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw GarimeCalendarMirrorError.notAuthorized
        }

        let readWindow = Self.window(around: now)
        let calendar = existingCalendar()
        let existing = calendar.map { mirroredEvents(in: readWindow, calendar: $0) } ?? []
        let actions = CalendarMirror.plan(
            tasks: tasks,
            existing: existing,
            in: Self.planningWindow(inside: readWindow)
        )
        guard !actions.isEmpty else {
            lastPlanSignature = nil
            repeatedPlanCount = 0
            return GarimeCalendarMirrorReport()
        }

        let signature = CalendarMirror.signature(for: actions)
        if signature == lastPlanSignature {
            repeatedPlanCount += 1
        } else {
            lastPlanSignature = signature
            repeatedPlanCount = 1
        }
        if repeatedPlanCount > Self.maxRepeatedPlans {
            if let lastPlanAttempt, now.timeIntervalSince(lastPlanAttempt) < Self.retryCooldown {
                return GarimeCalendarMirrorReport(
                    skipped: actions.count,
                    failureMessage: "espelhamento do calendário não converge; tentando de novo em instantes"
                )
            }
            repeatedPlanCount = 1
        }
        lastPlanAttempt = now

        let target: EKCalendar
        if let calendar {
            target = calendar
        } else {
            target = try makeCalendar()
        }

        var report = GarimeCalendarMirrorReport()
        var firstFailure: Error?
        for action in actions {
            do {
                try apply(action, in: target, report: &report)
            } catch {
                report.skipped += 1
                if firstFailure == nil { firstFailure = error }
            }
        }
        do {
            try store.commit()
        } catch {
            store.reset()
            throw error
        }
        report.failureMessage = firstFailure?.localizedDescription
        return report
    }

    static func window(around date: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -pastWindowDays, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: futureWindowDays, to: today) ?? today
        return DateInterval(start: start, end: end)
    }

    static func planningWindow(inside readWindow: DateInterval, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.date(byAdding: .day, value: boundaryMarginDays, to: readWindow.start)
        let end = calendar.date(byAdding: .day, value: -boundaryMarginDays, to: readWindow.end)
        guard let start, let end, start < end else { return readWindow }
        return DateInterval(start: start, end: end)
    }

    private func apply(_ action: CalendarMirrorAction, in target: EKCalendar, report: inout GarimeCalendarMirrorReport) throws {
        switch action {
        case .create(let entry):
            let event = EKEvent(eventStore: store)
            event.calendar = target
            apply(entry, to: event)
            try store.save(event, span: .thisEvent, commit: false)
            report.created += 1
        case .update(let eventId, let entry):
            guard let event = managedEvent(id: eventId, in: target) else { return }
            apply(entry, to: event)
            try store.save(event, span: .thisEvent, commit: false)
            report.updated += 1
        case .delete(let eventId):
            guard let event = managedEvent(id: eventId, in: target) else { return }
            try store.remove(event, span: .thisEvent, commit: false)
            report.deleted += 1
        }
    }

    private func existingCalendar() -> EKCalendar? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        if let cachedCalendarIdentifier,
           let calendar = store.calendar(withIdentifier: cachedCalendarIdentifier),
           calendar.title == CalendarMirror.calendarTitle,
           calendar.allowsContentModifications {
            return calendar
        }
        let match = store.calendars(for: .event).first {
            $0.title == CalendarMirror.calendarTitle && $0.allowsContentModifications
        }
        cachedCalendarIdentifier = match?.calendarIdentifier
        defaults.set(match?.calendarIdentifier, forKey: storageKey)
        return match
    }

    private func makeCalendar() throws -> EKCalendar {
        guard let source = preferredSource() else { throw GarimeCalendarMirrorError.noWritableSource }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = CalendarMirror.calendarTitle
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        cachedCalendarIdentifier = calendar.calendarIdentifier
        defaults.set(calendar.calendarIdentifier, forKey: storageKey)
        return calendar
    }

    private func preferredSource() -> EKSource? {
        let sources = store.sources
        if let iCloud = sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased() == "icloud" }) {
            return iCloud
        }
        if let calDAV = sources.first(where: { $0.sourceType == .calDAV }) {
            return calDAV
        }
        if let local = sources.first(where: { $0.sourceType == .local }) {
            return local
        }
        return store.defaultCalendarForNewEvents?.source
    }

    private func mirroredEvents(in window: DateInterval, calendar: EKCalendar) -> [CalendarMirrorEvent] {
        let predicate = store.predicateForEvents(
            withStart: window.start,
            end: window.end,
            calendars: [calendar]
        )
        return store.events(matching: predicate).compactMap { event in
            guard event.calendar?.calendarIdentifier == calendar.calendarIdentifier else { return nil }
            guard let taskId = CalendarMirror.taskId(inNotes: event.notes) else { return nil }
            guard let eventId = event.eventIdentifier else { return nil }
            return CalendarMirrorEvent(
                eventId: eventId,
                taskId: taskId,
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate ?? event.startDate,
                isAllDay: event.isAllDay
            )
        }
    }

    private func managedEvent(id: String, in calendar: EKCalendar) -> EKEvent? {
        guard let event = store.event(withIdentifier: id) else { return nil }
        guard event.calendar?.calendarIdentifier == calendar.calendarIdentifier else { return nil }
        guard CalendarMirror.isMirrored(notes: event.notes) else { return nil }
        return event
    }

    private func apply(_ entry: CalendarMirrorEntry, to event: EKEvent) {
        event.title = entry.title
        event.isAllDay = entry.isAllDay
        event.startDate = entry.start
        event.endDate = entry.end
        event.notes = entry.notes
    }
}
