import Combine
import EventKit
import Foundation

struct CalendarEventItem: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date?
    let isAllDay: Bool
    let calendarTitle: String?
}

@MainActor
final class EventKitService: ObservableObject {
    static let shared = EventKitService()

    let store = EKEventStore()

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

    var isCalendarAuthorized: Bool {
        calendarStatus == .fullAccess
    }

    @discardableResult
    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        changeToken &+= 1
        return granted
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
}

enum MobileDateFormatters {
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}
