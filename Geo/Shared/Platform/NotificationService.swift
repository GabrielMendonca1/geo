import Foundation
import UserNotifications

@MainActor
protocol NotificationService: Sendable {
    var authorizationStatus: UNAuthorizationStatus { get }
    func scheduleReminder(
        identifier: String,
        title: String,
        body: String,
        userInfo: [AnyHashable: Any]
    ) async throws
    func cancelAll()
    func requestAuthorization() async -> Bool
    func refreshAuthorizationStatus() async -> UNAuthorizationStatus
    func openSettings()
    func triggerTestNotification()
}

@MainActor
struct NotificationManagerAdapter: NotificationService, @unchecked Sendable {
    private let notificationManager: NotificationManager

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
    }

    var authorizationStatus: UNAuthorizationStatus {
        notificationManager.authorizationStatus
    }

    func scheduleReminder(
        identifier: String,
        title: String,
        body: String,
        userInfo: [AnyHashable: Any] = [:]
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func requestAuthorization() async -> Bool {
        await notificationManager.requestAuthorization()
    }

    func refreshAuthorizationStatus() async -> UNAuthorizationStatus {
        await notificationManager.refreshAuthorizationStatus()
        return notificationManager.authorizationStatus
    }

    func openSettings() {
        notificationManager.openNotificationSettings()
    }

    func triggerTestNotification() {
        notificationManager.triggerTestNotification()
    }
}
