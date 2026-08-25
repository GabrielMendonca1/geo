import SwiftUI

final class DockState: ObservableObject {
    @Published var hidden = false
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
        case "money": MoneyView()
        case "terminal": AgentHomeView()
        default: TodayView()
        }
    }

    private var dock: some View {
        HStack(spacing: 4) {
            dockItem("calendar", "Tarefas", tag: "today")
            dockItem("figure.strengthtraining.traditional", "Saúde", tag: "health")
            dockItem("dollarsign.circle", "Dinheiro", tag: "money")
            dockItem("terminal", "Agente", tag: "terminal")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .strokeBorder(Color.slateStroke.opacity(0.5))
                )
                .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
    }

    private func dockItem(_ symbol: String, _ label: String, tag: String) -> some View {
        let active = selection == tag
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { selection = tag }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 32)
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .opacity(active ? 1 : 0.45)
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 62)
            .contentShape(Rectangle())
            .background(active ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
        let valid = ["today", "health", "money", "terminal"]
        
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
