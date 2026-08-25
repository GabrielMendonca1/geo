import SwiftUI

final class DockState: ObservableObject {
    @Published var hidden = false
    /// Verdadeiro enquanto o usuário está rolando a tela.
    @Published var scrolling = false
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
        let shrunk = dockState.scrolling
        return HStack(spacing: 4) {
            dockItem("calendar", "Tarefas", tag: "today")
            dockItem("figure.strengthtraining.traditional", "Saúde", tag: "health")
            dockItem("terminal", "Agente", tag: "terminal")
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.slateStroke.opacity(0.4))
                )
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        )
        .scaleEffect(shrunk ? 0.8 : 1, anchor: .bottom)
        .opacity(shrunk ? 0.9 : 1)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: shrunk)
    }

    private func dockItem(_ symbol: String, _ label: String, tag: String) -> some View {
        let active = selection == tag
        return Button {
            guard !active else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { selection = tag }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .frame(width: 60, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
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
