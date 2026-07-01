import AppKit
import EventKit

final class CalendarPermission: Permission, @unchecked Sendable {
    let id = "calendar"
    let displayName = "Calendar"
    let description = "Required to show and manage your events alongside tasks"

    var privacyPaneURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    func checkStatus() -> PermissionState {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    func request() async -> PermissionState {
        let current = checkStatus()
        if current != .notDetermined { return current }
        _ = await EventKitAdapter.shared.requestAccess()
        return checkStatus()
    }

    private static func map(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .authorized
        case .writeOnly: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }
}
