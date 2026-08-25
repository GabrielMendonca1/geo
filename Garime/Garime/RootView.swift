import SwiftUI

final class DockState: ObservableObject {
    @Published var hidden = false
    /// Verdadeiro quando o usuário está descendo na lista: o dock encolhe
    /// e volta ao tamanho normal ao subir ou ao chegar no topo.
    @Published var collapsed = false
}

private struct DockStateKey: EnvironmentKey {
    static let defaultValue: DockState? = nil
}

extension EnvironmentValues {
    var dockState: DockState? {
        get { self[DockStateKey.self] }
        set { self[DockStateKey.self] = newValue }
    }
}

/// Decide o tamanho do dock a partir do deslocamento da lista.
enum DockScrollRule {
    /// Perto do topo o dock sempre volta ao tamanho normal.
    static let topThreshold: CGFloat = 12
    /// Movimento menor que isso é tremor de dedo, não intenção.
    static let moveThreshold: CGFloat = 6

    static func collapsed(was current: Bool, from old: CGFloat, to new: CGFloat) -> Bool {
        if new <= topThreshold { return false }
        let delta = new - old
        guard abs(delta) > moveThreshold else { return current }
        return delta > 0
    }
}

/// Encolhe o dock quando a lista desce e o devolve quando sobe. Precisa ser
/// aplicado direto na ScrollView/List da tela: o pai não recebe esses eventos.
private struct DockScrollTracking: ViewModifier {
    @Environment(\.dockState) private var dock

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { old, new in
                guard let dock else { return }
                let collapsed = DockScrollRule.collapsed(was: dock.collapsed, from: old, to: new)
                guard dock.collapsed != collapsed else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                    dock.collapsed = collapsed
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func dockScrollTracking() -> some View {
        modifier(DockScrollTracking())
    }
}

struct RootView: View {
    @State private var selection: String = RootView.initialTab()
    @StateObject private var dockState = DockState()
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system.rawValue
    @State private var showSettings = RootView.shouldOpenSettings()

    init() {
        AirAppearance.apply()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            dockContent
                .environmentObject(dockState)
                .environment(\.dockState, dockState)
            if !dockState.hidden {
                dock
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: dockState.hidden)
        .tint(Color.slateText)
        .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
        .sheet(isPresented: $showSettings) {
            SettingsView(initialSection: RootView.settingsSection())
        }
    }

    @ViewBuilder
    private var dockContent: some View {
        switch selection {
        case "health": HealthView()
        case "terminal": AgentHomeView()
        default: TodayView()
        }
    }

    private var dock: some View {
        let collapsed = dockState.collapsed
        let radius: CGFloat = collapsed ? 21 : 34
        return HStack(spacing: collapsed ? 2 : 6) {
            dockItem("calendar", "Tarefas", tag: "today", collapsed: collapsed)
            dockItem("figure.strengthtraining.traditional", "Saúde", tag: "health", collapsed: collapsed)
            dockItem("terminal", "Agente", tag: "terminal", collapsed: collapsed)
        }
        .padding(collapsed ? 4 : 6)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.slateStroke.opacity(0.4))
                )
                .shadow(color: .black.opacity(0.18), radius: collapsed ? 10 : 16, y: 5)
        )
        .padding(.horizontal, collapsed ? 0 : 14)
        .padding(.bottom, 2)
        .accessibilityIdentifier("dock")
    }

    private func dockItem(_ symbol: String, _ label: String, tag: String, collapsed: Bool) -> some View {
        let active = selection == tag
        return Button {
            guard !active else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { selection = tag }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: collapsed ? 16 : 25, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .frame(maxWidth: collapsed ? 44 : .infinity, minHeight: collapsed ? 30 : 56)
                .background(
                    RoundedRectangle(cornerRadius: collapsed ? 13 : 26, style: .continuous)
                        .fill(active ? Color.primary.opacity(0.13) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private static func shouldOpenSettings() -> Bool {
        CommandLine.arguments.contains("-geoOpenSettings")
    }

    private static func settingsSection() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "-geoOpenSettings"),
              index + 1 < CommandLine.arguments.count
        else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func initialTab() -> String {
        let valid = ["today", "health", "terminal"]
        
        if let index = CommandLine.arguments.firstIndex(of: "-geoTab"),
           index + 1 < CommandLine.arguments.count {
            let launchArg = CommandLine.arguments[index + 1]
            if valid.contains(launchArg) {
                return launchArg
            }
        }
        
        let stored = UserDefaults.standard.string(forKey: "geoTab")
        if stored == "tasks" { return "today" }
        if let stored, valid.contains(stored) { return stored }
        return "today"
    }
}

#Preview {
    RootView()
}
