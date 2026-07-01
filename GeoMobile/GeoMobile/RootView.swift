import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "calendar")
                }
            TasksView()
                .tabItem {
                    Label("Tasks", systemImage: "checklist")
                }
        }
    }
}

#Preview {
    RootView()
}
