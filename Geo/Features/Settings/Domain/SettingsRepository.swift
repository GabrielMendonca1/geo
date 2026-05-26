import Foundation
import UserNotifications

@MainActor
protocol SettingsRepository: Sendable {
    func loadSnapshot() -> SettingsSnapshot
    func persistAlwaysOnTop(_ isEnabled: Bool)
    func persistEditorFontSize(_ size: Double)

    func refreshPermissions()
    func requestPermission(_ id: String) async -> PermissionState
    func requestAllPermissions() async -> [String: PermissionState]
    func openPermissionSettings(for id: String)

    func refreshNotificationAuthorizationStatus() async -> UNAuthorizationStatus
    func requestNotificationAuthorization() async -> Bool
    func openNotificationSettings()
    func triggerTestNotification()

    func updateScreenshotFolder(to url: URL)
    func defaultDesktopFolder() -> URL
    func revealInFinder(_ url: URL)
    func runOCRSelfTest() async -> String
}
