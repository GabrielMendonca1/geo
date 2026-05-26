import AppKit
import CoreGraphics

final class InputMonitoringPermission: Permission, @unchecked Sendable {
    let id = "inputMonitoring"
    let displayName = "Input Monitoring"
    let description = "Required for global hotkey detection"

    var privacyPaneURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func checkStatus() -> PermissionState {
        let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        )

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            return .authorized
        }
        return .notDetermined
    }

    func request() async -> PermissionState {
        let current = checkStatus()
        if current.isGranted { return current }

        openSystemSettings()
        return .notDetermined
    }
}
