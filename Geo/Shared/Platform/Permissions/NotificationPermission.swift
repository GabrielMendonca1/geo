import AppKit
import UserNotifications

final class NotificationPermission: Permission, @unchecked Sendable {
    let id = "notifications"
    let displayName = "Notifications"
    let description = "Required for task reminders and alerts"

    var privacyPaneURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
    }

    func checkStatus() -> PermissionState {
        let semaphore = DispatchSemaphore(value: 0)
        var result: PermissionState = .unknown
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            result = Self.map(settings.authorizationStatus)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    func request() async -> PermissionState {
        let current = checkStatus()
        if current != .notDetermined { return current }

        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
        }
        return checkStatus()
    }

    private static func map(_ status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        @unknown default: return .unknown
        }
    }
}
