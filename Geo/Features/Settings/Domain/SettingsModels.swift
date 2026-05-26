import Foundation
import UserNotifications

struct SettingsCaptureSnapshot {
    var fileName: String? = nil
    var processedAt: Date? = nil
    var textLength: Int? = nil
}

struct SettingsSnapshot {
    var alwaysOnTop: Bool
    var editorFontSize: Double
    var screenshotFolder: URL
    var isScreenshotFolderValid: Bool
    var accessibility: PermissionState
    var inputMonitoring: PermissionState
    var notificationAuthorizationStatus: UNAuthorizationStatus
    var captureSnapshot: SettingsCaptureSnapshot
}

enum SettingsPreferenceKey: CaseIterable {
    case alwaysOnTop
    case editorFontSize

    var storageKey: String {
        switch self {
        case .alwaysOnTop:
            return AlwaysOnTop.settingsKey
        case .editorFontSize:
            return EditorTypographyPreferences.fontSizeKey
        }
    }
}
