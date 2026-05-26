import Combine
import Foundation

protocol PermissionService: Sendable {
    func checkPermission(_ id: String) -> PermissionState
    func requestPermission(_ id: String) async -> PermissionState
    func observeStatus() -> AsyncStream<[String: PermissionState]>
    func requestAllPermissions() async -> [String: PermissionState]
    func refreshPermissions()
    func openSettings(for id: String)
}

private final class PermissionObservationBox: @unchecked Sendable {
    var cancellable: AnyCancellable?
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

    func observeStatus() -> AsyncStream<[String: PermissionState]> {
        AsyncStream { continuation in
            let box = PermissionObservationBox()
            MainActor.assumeIsolated {
                continuation.yield(permissionRegistry.states)
                box.cancellable = permissionRegistry.$states
                    .dropFirst()
                    .sink { states in
                        continuation.yield(states)
                    }
            }

            continuation.onTermination = { @Sendable _ in
                box.cancellable?.cancel()
                box.cancellable = nil
            }
        }
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
