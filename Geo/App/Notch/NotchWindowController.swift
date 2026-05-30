import AppKit
import SwiftUI
import Combine

@MainActor
final class NotchWindowController {
    private let stateStore: NotchStateStore
    private let environment: AppEnvironment
    private var panel: NotchPanel?
    private var dropView: NotchDropView?
    private var host: NSHostingView<AnyView>?
    private var metrics: NotchMetrics?
    private let hoverMonitor = NotchHoverMonitor()
    private let dropZonePanel = NotchDropZonePanel()
    private var screenChangeObserver: NSObjectProtocol?
    private var stateCancellable: AnyCancellable?
    private var dragCancellable: AnyCancellable?

    init(stateStore: NotchStateStore, environment: AppEnvironment) {
        self.stateStore = stateStore
        self.environment = environment
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    func show() {
        guard let screen = NSScreen.preferred else { return }
        install(on: screen)
        dropZonePanel.show(on: screen, stateStore: stateStore)
        observeScreenChanges()
        wireHoverMonitor()
        observeStateChanges()
    }

    func hide() {
        hoverMonitor.stop()
        dropZonePanel.hide()
        panel?.orderOut(nil)
        panel = nil
        dropView = nil
        host = nil
    }

    private func install(on screen: NSScreen) {
        let metrics = NotchMetrics(screen: screen)
        self.metrics = metrics

        let panel = NotchPanel(
            contentRect: metrics.panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        let dropView = NotchDropView(frame: CGRect(origin: .zero, size: metrics.panelSize))
        dropView.isActive = stateStore.state != .hidden
        dropView.onDragEnter = { [weak self] in
            Task { @MainActor in self?.stateStore.dragEntered() }
        }
        dropView.onDragExit = { [weak self] in
            Task { @MainActor in self?.stateStore.dragExited() }
        }
        dropView.onDrop = { items in
            Task { @MainActor in items.forEach { ShelfStore.shared.addItem($0) } }
        }

        let host = NSHostingView(rootView: makeRoot(metrics: metrics))
        host.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            host.topAnchor.constraint(equalTo: dropView.topAnchor),
            host.bottomAnchor.constraint(equalTo: dropView.bottomAnchor)
        ])

        panel.contentView = dropView
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = true

        self.panel = panel
        self.dropView = dropView
        self.host = host
        updateMousePassthrough()
    }

    private func makeRoot(metrics: NotchMetrics) -> AnyView {
        AnyView(
            NotchRootView(stateStore: stateStore, metrics: metrics)
                .environment(\.appEnvironment, environment)
        )
    }

    private func reposition(on screen: NSScreen) {
        guard let panel, let dropView, let host else { install(on: screen); return }
        let metrics = NotchMetrics(screen: screen)
        self.metrics = metrics
        dropView.frame = CGRect(origin: .zero, size: metrics.panelSize)
        panel.setFrame(metrics.panelFrame, display: true)
        host.rootView = makeRoot(metrics: metrics)
        updateMousePassthrough()
    }

    private func updateMousePassthrough() {
        guard let panel, let dropView else { return }
        if stateStore.isDragActive {
            panel.ignoresMouseEvents = false
            return
        }
        let windowPoint = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        panel.ignoresMouseEvents = dropView.hitTest(windowPoint) == nil
    }

    private func observeScreenChanges() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let screen = NSScreen.preferred else { return }
                self.reposition(on: screen)
            }
        }
    }

    private func wireHoverMonitor() {
        hoverMonitor.zoneProvider = { [weak self] in self?.currentHoverZone() ?? .zero }
        hoverMonitor.onEnter = { [weak self] in self?.stateStore.hoverBegan() }
        hoverMonitor.onExit = { [weak self] in self?.stateStore.hoverEnded() }
        hoverMonitor.onTick = { [weak self] in self?.updateMousePassthrough() }
        hoverMonitor.start()
    }

    private func observeStateChanges() {
        stateCancellable = stateStore.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                self?.dropView?.isActive = newState != .hidden
                self?.updateMousePassthrough()
                self?.hoverMonitor.check()
            }
    }

    private func currentHoverZone() -> NSRect {
        guard let metrics else { return .zero }
        switch stateStore.state {
        case .hidden: return metrics.hiddenHoverRect
        case .expanded: return metrics.expandedHoverRect
        }
    }
}
