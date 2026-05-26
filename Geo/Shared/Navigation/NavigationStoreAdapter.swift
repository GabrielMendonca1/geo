import Observation

struct NavigationStoreAdapter: NavigationRepository, @unchecked Sendable {
    private let navigationStore: NavigationStore

    init(navigationStore: NavigationStore) {
        self.navigationStore = navigationStore
    }

    func selectTab(_ tab: AppTab) {
        navigationStore.selectTab(tab)
    }

    func observeTab() -> AsyncStream<AppTab> {
        let router = navigationStore.tabRouter
        return AsyncStream { continuation in
            continuation.yield(router.selectedTab)
            let task = Task { @MainActor in
                var lastTab = router.selectedTab
                while !Task.isCancelled {
                    let newTab: AppTab = await withCheckedContinuation { inner in
                        withObservationTracking {
                            _ = router.selectedTab
                        } onChange: {
                            Task { @MainActor in
                                inner.resume(returning: router.selectedTab)
                            }
                        }
                    }
                    if newTab != lastTab {
                        continuation.yield(newTab)
                        lastTab = newTab
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func pushPath(_ pathComponent: String) {
        navigationStore.pushPath(pathComponent)
    }

    func popPath() {
        navigationStore.popPath()
    }
}
