protocol NavigationRepository: Sendable {
    func selectTab(_ tab: AppTab)
    func observeTab() -> AsyncStream<AppTab>
    func pushPath(_ pathComponent: String)
    func popPath()
}
