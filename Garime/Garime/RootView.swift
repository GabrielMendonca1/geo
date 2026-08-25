import SwiftUI

final class DockState: ObservableObject {
    @Published var hidden = false
    /// Verdadeiro enquanto o usuário está rolando a tela.
    @Published var scrolling = false
    /// nil = automático (rolagem); true/false = escolha manual por toque.
    @Published var manuallyExpanded: Bool?

    var expanded: Bool {
        manuallyExpanded ?? !scrolling
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
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard abs(value.translation.height) > 12 else { return }
                            if !dockState.scrolling {
                                dockState.scrolling = true
                            }
                        }
                        .onEnded { _ in
                            dockState.scrolling = false
                        }
                )
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
        let expanded = dockState.expanded
        return HStack(spacing: 2) {
            dockItem("calendar", "Tarefas", tag: "today", expanded: expanded)
            dockItem("figure.strengthtraining.traditional", "Saúde", tag: "health", expanded: expanded)
            dockItem("terminal", "Agente", tag: "terminal", expanded: expanded)
        }
        .padding(.horizontal, expanded ? 14 : 10)
        .padding(.vertical, expanded ? 6 : 4)
        .background(
            RoundedRectangle(cornerRadius: expanded ? 27 : 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: expanded ? 27 : 22, style: .continuous)
                        .strokeBorder(Color.slateStroke.opacity(0.5))
                )
                .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: expanded)
    }

    private func dockItem(_ symbol: String, _ label: String, tag: String, expanded: Bool) -> some View {
        let active = selection == tag
        return Button {
            if active {
                dockState.manuallyExpanded = !(dockState.manuallyExpanded ?? dockState.expanded)
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { selection = tag }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: expanded ? 19 : 17, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 22)
                if expanded {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .opacity(active ? 1 : 0.45)
                        .fixedSize()
                }
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .padding(.horizontal, expanded ? 18 : 14)
            .frame(maxWidth: .infinity, minHeight: expanded ? 48 : 36)
            .contentShape(Rectangle())
            .background(active ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: expanded ? 21 : 17, style: .continuous))
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
