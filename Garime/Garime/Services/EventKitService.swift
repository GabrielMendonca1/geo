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

@MainActor
final class EventKitService: ObservableObject {
    static let shared = EventKitService()

    let store = EKEventStore()

    @Published private(set) var changeToken = 0
    private(set) var mirrorErrorMessage: String?

    private(set) lazy var mirror = GarimeCalendarMirrorService(store: store)

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

    func syncMirror(tasks: [TaskItem]) {
        guard isCalendarAuthorized else {
            mirrorErrorMessage = nil
            return
        }
        do {
            mirrorErrorMessage = try mirror.sync(tasks: tasks).failureMessage
        } catch {
            mirrorErrorMessage = error.localizedDescription
        }
    }

    func events(in interval: DateInterval) -> [CalendarEventItem] {
        guard isCalendarAuthorized else { return [] }
        let mirrorCalendarIdentifier = mirror.calendarIdentifier
        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: nil
        )
        return store.events(matching: predicate)
            .filter { event in
                if let mirrorCalendarIdentifier, event.calendar?.calendarIdentifier == mirrorCalendarIdentifier {
                    return false
                }
                return !CalendarMirror.isMirrored(notes: event.notes)
            }
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
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "HH:mm"
        return f
    }()
}
