import SwiftUI

enum AppTab: String, CaseIterable {
    case tasks = "Tasks"
    case nodes = "Nodes"
    case nano = "Nano"
    case brains = "Brains"
    case settings = "Settings"

    static let defaultNavigationOrder: [AppTab] = [.nodes, .nano, .tasks, .brains]

    func nextTab() -> AppTab? {
        let order = Self.defaultNavigationOrder
        guard let index = order.firstIndex(of: self) else { return nil }
        let next = index + 1
        return next < order.count ? order[next] : nil
    }

    func previousTab() -> AppTab? {
        let order = Self.defaultNavigationOrder
        guard let index = order.firstIndex(of: self) else { return nil }
        let prev = index - 1
        return prev >= 0 ? order[prev] : nil
    }

    var displayTitle: String {
        switch self {
        case .tasks: return "Tasks"
        case .nodes: return "Brain"
        case .nano: return "Agent"
        case .brains: return "Brainsets"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .tasks: return "checklist.unchecked"
        case .nodes: return "brain.head.profile"
        case .nano: return "sparkles"
        case .brains: return "point.3.connected.trianglepath.dotted"
        case .settings: return "gearshape"
        }
    }

    var shortcutHint: String {
        if self == .settings { return "⌘," }
        if let index = Self.defaultNavigationOrder.firstIndex(of: self) {
            return "⌘\(index + 1)"
        }
        return ""
    }

}

extension AppTab: Identifiable {
    var id: Self { self }
}

extension AppTab {
    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .tasks:
            TasksPane()
        case .nodes:
            NodesPane()
        case .nano:
            NanoPane()
        case .brains:
            BrainsPane()
        case .settings:
            SettingsPane()
        }
    }
}
