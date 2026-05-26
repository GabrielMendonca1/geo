import AppKit
import ApplicationServices

final class AccessibilityPermission: Permission, @unchecked Sendable {
    let id = "accessibility"
    let displayName = "Accessibility"
    let description = "Required for global keyboard shortcuts"

    var privacyPaneURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func checkStatus() -> PermissionState {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .authorized : .notDetermined
    }

    func request() async -> PermissionState {
        let current = checkStatus()
        if current.isGranted { return current }
        openSystemSettings()
        return checkStatus()
    }
}
