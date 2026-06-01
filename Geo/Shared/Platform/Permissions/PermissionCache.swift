import Foundation

final class PermissionCache: @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix = "permission.cache."
    private let queue = DispatchQueue(label: "com.geo.permissionCache")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func get(_ permissionId: String) -> CachedPermission? {
        queue.sync {
            guard let data = defaults.data(forKey: prefix + permissionId),
                  let cached = try? JSONDecoder().decode(CachedPermission.self, from: data) else {
                return nil
            }
            return cached
        }
    }

    func set(_ permissionId: String, state: PermissionState) {
        queue.sync {
            let cached = CachedPermission(state: state, timestamp: Date())
            if let data = try? JSONEncoder().encode(cached) {
                defaults.set(data, forKey: prefix + permissionId)
            }
        }
    }

    func invalidate(_ permissionId: String) {
        queue.sync {
            defaults.removeObject(forKey: prefix + permissionId)
        }
    }
}

struct CachedPermission: Codable {
    let state: PermissionState
    let timestamp: Date

    var isStale: Bool {
        Date().timeIntervalSince(timestamp) > 300
    }
}
