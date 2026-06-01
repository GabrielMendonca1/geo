import Foundation
import Combine

@MainActor
final class PermissionRegistry: ObservableObject {
    static let shared = PermissionRegistry()

    private static let defaultRequestOrder = ["accessibility", "inputMonitoring", "notifications"]

    private var permissions: [String: any Permission] = [:]
    private let cache: PermissionCache

    @Published var states: [String: PermissionState] = [:]

    var allGranted: Bool {
        states.values.allSatisfy { $0.isGranted }
    }

    var accessibility: PermissionState { states["accessibility"] ?? .unknown }
    var inputMonitoring: PermissionState { states["inputMonitoring"] ?? .unknown }
    var notifications: PermissionState { states["notifications"] ?? .unknown }

    private init(cache: PermissionCache = PermissionCache()) {
        self.cache = cache
        guard !ProcessInfo.processInfo.isRunningTests else {
            for id in Self.defaultRequestOrder {
                states[id] = .authorized
            }
            return
        }
        registerDefaults()
        refreshAll()
    }

    private func registerDefaults() {
        register(AccessibilityPermission())
        register(InputMonitoringPermission())
        register(NotificationPermission())
    }

    func register(_ permission: any Permission) {
        permissions[permission.id] = permission
    }

    func permission(for id: String) -> (any Permission)? {
        permissions[id]
    }

    func check(_ id: String, useCache: Bool = true) -> PermissionState {
        guard let permission = permission(for: id) else { return .unknown }

        if useCache, let cached = cache.get(id), !cached.isStale {
            return cached.state
        }

        let state = permission.checkStatus()
        cache.set(id, state: state)
        states[id] = state

        return state
    }

    func request(_ id: String) async -> PermissionState {
        guard let permission = permission(for: id) else { return .unknown }

        cache.invalidate(id)
        let state = await permission.request()
        cache.set(id, state: state)
        states[id] = state

        return state
    }

    func requestAll() async -> [String: PermissionState] {
        var results: [String: PermissionState] = [:]
        let registeredIDs = Set(permissions.keys)
        let prioritized = Self.defaultRequestOrder.filter { registeredIDs.contains($0) }
        let remaining = registeredIDs.subtracting(prioritized).sorted()
        let ids = prioritized + remaining

        for id in ids {
            results[id] = await request(id)
        }

        return results
    }

    func refreshAll() {
        let ids = Array(permissions.keys)
        var updated = states
        for id in ids {
            guard let permission = permission(for: id) else { continue }
            let state = permission.checkStatus()
            cache.set(id, state: state)
            updated[id] = state
        }
        DispatchQueue.main.async { self.states = updated }
    }

    func openSettings(for id: String) {
        permission(for: id)?.openSystemSettings()
    }
}
