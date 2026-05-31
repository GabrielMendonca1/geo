import SwiftUI

private struct TabIsActiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var tabIsActive: Bool {
        get { self[TabIsActiveKey.self] }
        set { self[TabIsActiveKey.self] = newValue }
    }
}

struct UnifiedNavigationContainer: View {
    @Environment(\.tabRouter) private var tabRouter
    @State private var lruOrder: [AppTab] = []
    private let maxLiveTabs = AppTab.allCases.count

    private var liveTabs: Set<AppTab> {
        var tabs = Set<AppTab>()
        tabs.insert(tabRouter.selectedTab)
        for tab in lruOrder.reversed() where tabs.count < maxLiveTabs {
            tabs.insert(tab)
        }
        return tabs
    }

    var body: some View {
        let selected = tabRouter.selectedTab
        let live = liveTabs
        ZStack {
            ForEach(AppTab.allCases) { tab in
                if live.contains(tab) {
                    tab.destinationView
                        .environment(\.tabIsActive, selected == tab)
                        .opacity(selected == tab ? 1 : 0)
                        .allowsHitTesting(selected == tab)
                        .zIndex(selected == tab ? 1 : 0)
                }
            }
        }
        .task {
            touchLRU(tabRouter.selectedTab)
        }
        .onChange(of: tabRouter.selectedTab) { _, newTab in
            Task { @MainActor in touchLRU(newTab) }
        }
    }

    private func touchLRU(_ tab: AppTab) {
        var order = lruOrder
        order.removeAll { $0 == tab }
        order.append(tab)
        if order.count > maxLiveTabs {
            order.removeFirst(order.count - maxLiveTabs)
        }
        lruOrder = order
    }
}

#Preview {
    UnifiedNavigationContainer()
        .environment(\.tabRouter, TabRouter())
}
