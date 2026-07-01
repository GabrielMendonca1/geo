import Combine
import EventKit
import Foundation
import GeoCore

struct CalendarEventItem: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date?
    let isAllDay: Bool
    let calendarTitle: String?
}

struct ReminderItem: Identifiable, Hashable {
    let id: String
    let title: String
    let isCompleted: Bool
    let dueDate: Date?
    let isRecurring: Bool
    let calendarTitle: String?

    var kind: TaskKind { isRecurring ? .habit : .task }
}

@MainActor
final class EventKitService: ObservableObject {
    static let shared = EventKitService()

    let store = EKEventStore()
    private static let geoListTitle = "Geo"

    @Published private(set) var changeToken = 0

    init() {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.changeToken &+= 1 }
        }
    }

    var calendarStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    var remindersStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    var isCalendarAuthorized: Bool {
        calendarStatus == .fullAccess
    }

    var isRemindersAuthorized: Bool {
        switch remindersStatus {
        case .fullAccess, .writeOnly: return true
        default: return false
        }
    }

    @discardableResult
    func requestAccess() async -> Bool {
        async let calendar = (try? store.requestFullAccessToEvents()) ?? false
        async let reminders = (try? store.requestFullAccessToReminders()) ?? false
        let calendarGranted = await calendar
        let remindersGranted = await reminders
        changeToken &+= 1
        return calendarGranted && remindersGranted
    }

    func events(in interval: DateInterval) -> [CalendarEventItem] {
        guard isCalendarAuthorized else { return [] }
        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: nil
        )
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { ek in
                let resolvedId = ek.eventIdentifier ?? ek.calendarItemIdentifier
                let title = (ek.title?.isEmpty == false) ? ek.title! : "Untitled Event"
                return CalendarEventItem(
                    id: "ek-" + resolvedId,
                    title: title,
                    start: ek.startDate,
                    end: ek.endDate,
                    isAllDay: ek.isAllDay,
                    calendarTitle: ek.calendar?.title
                )
            }
    }

    func fetchReminders(timeout: TimeInterval = 5) async -> [ReminderItem] {
        guard isRemindersAuthorized else { return [] }
        let predicate = store.predicateForReminders(in: nil)
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            store.fetchReminders(matching: predicate) { reminders in
                once.fire { continuation.resume(returning: reminders ?? []) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                once.fire { continuation.resume(returning: []) }
            }
        }
        return fetched.map { reminder in
            ReminderItem(
                id: reminder.calendarItemIdentifier,
                title: reminder.title ?? "Untitled",
                isCompleted: reminder.isCompleted,
                dueDate: reminder.dueDateComponents?.date,
                isRecurring: reminder.hasRecurrenceRules,
                calendarTitle: reminder.calendar?.title
            )
        }
    }

    @discardableResult
    func toggleCompleted(reminderID: String) -> Bool {
        guard isRemindersAuthorized,
              let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder
        else { return false }
        reminder.isCompleted.toggle()
        do {
            try store.save(reminder, commit: true)
            changeToken &+= 1
            return true
        } catch {
            return false
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func fire(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}

enum MobileDateFormatters {
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
