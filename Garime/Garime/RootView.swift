import SwiftUI

struct RootView: View {
    @State private var selection: String = RootView.initialTab()
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system.rawValue
    @State private var showSettings = RootView.shouldOpenSettings()

    init() {
        AirAppearance.apply()
    }

    var body: some View {
        tabs
            .tint(Color.slateText)
            .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
            .sheet(isPresented: $showSettings) {
                SettingsView(initialSection: RootView.settingsSection())
            }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26.0, *) {
            tabView.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            tabView
        }
    }

    private var tabView: some View {
        TabView(selection: $selection) {
            TodayView()
                .tabItem {
                    Image(systemName: "calendar")
                        .accessibilityLabel("Tarefas")
                }
                .tag("today")

            HealthView()
                .tabItem {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .accessibilityLabel("Saúde")
                }
                .tag("health")

            AgentHomeView()
                .tabItem {
                    Image(systemName: "terminal")
                        .accessibilityLabel("Agente")
                }
                .tag("terminal")
        }
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
