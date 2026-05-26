import Foundation

enum NanoProvider: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

@MainActor
final class NanoProviderStore: ObservableObject {
    static let defaultsKey = "nano.provider"

    @Published private(set) var current: NanoProvider

    init() {
        let stored = UserDefaults.standard.string(forKey: NanoProviderStore.defaultsKey) ?? ""
        self.current = NanoProvider(rawValue: stored) ?? .claude
    }

    static let providerChangedNotification = Notification.Name("ai.geo.nano.providerChanged")

    func setProvider(_ provider: NanoProvider) {
        guard provider != current else { return }
        current = provider
        UserDefaults.standard.set(provider.rawValue, forKey: NanoProviderStore.defaultsKey)
        NotificationCenter.default.post(name: Self.providerChangedNotification, object: provider.rawValue)
    }
}
