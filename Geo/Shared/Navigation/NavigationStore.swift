import SwiftUI

@Observable
final class TabRouter {
    var selectedTab: AppTab = .home

    init(selectedTab: AppTab? = nil) {
        if let explicit = selectedTab {
            self.selectedTab = explicit
        }
    }

    func selectTab(_ tab: AppTab) {
        let start = CFAbsoluteTimeGetCurrent()
        let from = selectedTab.rawValue
        selectedTab = tab
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        PerformanceTracker.shared.trackTabSwitch(from: from, to: tab.rawValue, durationMs: ms)
    }
}

@Observable
final class NavigationStore {
    let tabRouter: TabRouter
    private(set) var path: [String] = []
    var searchPresentedTabs: [AppTab: Bool] = [:]
    var searchTexts: [AppTab: String] = [:]
    var fabExpanded: Bool = false

    var selectedTab: AppTab {
        get { tabRouter.selectedTab }
        set { tabRouter.selectTab(newValue) }
    }

    var isSearchPresented: Bool {
        get { searchPresentedTabs[tabRouter.selectedTab, default: false] }
        set { searchPresentedTabs[tabRouter.selectedTab] = newValue }
    }

    var searchText: String {
        get { searchTexts[tabRouter.selectedTab, default: ""] }
        set { searchTexts[tabRouter.selectedTab] = newValue }
    }

    var searchVisible: Bool {
        tabRouter.selectedTab.supportsSearch
    }

    init(selectedTab: AppTab? = nil) {
        self.tabRouter = TabRouter(selectedTab: selectedTab)
    }

    func selectTab(_ tab: AppTab) {
        tabRouter.selectTab(tab)
        fabExpanded = false
    }

    func pushPath(_ pathComponent: String) {
        let trimmed = pathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        path.append(trimmed)
    }

    func popPath() {
        _ = path.popLast()
    }
}
