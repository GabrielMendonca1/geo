import Foundation
import AppKit

enum PermissionState: String, Codable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unknown

    var isGranted: Bool { self == .authorized }
    var canRequest: Bool { self == .notDetermined }
}

protocol Permission: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }
    var privacyPaneURL: URL? { get }

    func checkStatus() -> PermissionState
    func request() async -> PermissionState
}

extension Permission {
    func openSystemSettings() {
        guard let url = privacyPaneURL else { return }
        NSWorkspace.shared.open(url)
    }
}
