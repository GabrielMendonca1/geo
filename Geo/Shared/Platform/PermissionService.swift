import Foundation

protocol PermissionService: Sendable {
    func checkPermission(_ id: String) -> PermissionState
    func requestPermission(_ id: String) async -> PermissionState
    func requestAllPermissions() async -> [String: PermissionState]
    func refreshPermissions()
    func openSettings(for id: String)
}

struct PermissionRegistryAdapter: PermissionService, @unchecked Sendable {
    private let permissionRegistry: PermissionRegistry

    init(permissionRegistry: PermissionRegistry) {
        self.permissionRegistry = permissionRegistry
    }

    func checkPermission(_ id: String) -> PermissionState {
        MainActor.assumeIsolated {
            permissionRegistry.check(id)
        }
    }

    func requestPermission(_ id: String) async -> PermissionState {
        await permissionRegistry.request(id)
    }

    func requestAllPermissions() async -> [String: PermissionState] {
        await permissionRegistry.requestAll()
    }

    func refreshPermissions() {
        MainActor.assumeIsolated {
            permissionRegistry.refreshAll()
        }
    }

    func openSettings(for id: String) {
        MainActor.assumeIsolated {
            permissionRegistry.openSettings(for: id)
        }
    }
}
