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
        CGPreflightListenEventAccess() ? .authorized : .notDetermined
    }

    func request() async -> PermissionState {
        if CGPreflightListenEventAccess() { return .authorized }
        return CGRequestListenEventAccess() ? .authorized : .notDetermined
    }
}
