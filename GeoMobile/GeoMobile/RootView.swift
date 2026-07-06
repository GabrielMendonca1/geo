import SwiftUI

struct RootView: View {
    @State private var selection: String = RootView.initialTab()

    init() {
        AirAppearance.apply()
    }

    var body: some View {
        TabView(selection: $selection) {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "calendar")
                }
                .tag("today")
            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .tag("chat")
            AgentsView()
                .tabItem {
                    Label("Agents", systemImage: "cpu")
                }
                .tag("agents")
        }
        .tint(.actionBlue)
    }

    private static func initialTab() -> String {
        let valid = ["today", "chat", "agents"]
        let stored = UserDefaults.standard.string(forKey: "geoTab")
        if stored == "tasks" { return "today" }
        if let stored, valid.contains(stored) { return stored }
        return "today"
    }
}

#Preview {
    RootView()
}
