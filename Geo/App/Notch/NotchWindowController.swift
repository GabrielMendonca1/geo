import AppKit
import SwiftUI
import Combine

@MainActor
final class NotchWindowController {
    private let stateStore: NotchStateStore
    private let environment: AppEnvironment
    private var panel: NotchPanel?
    private var dropView: NotchDropView?
    private let hoverMonitor = NotchHoverMonitor()
    private let dropZonePanel = NotchDropZonePanel()
    private var installedScreen: NSScreen?
    private var screenChangeObserver: NSObjectProtocol?
    private var stateCancellable: AnyCancellable?

    init(
        stateStore: NotchStateStore,
        environment: AppEnvironment
    ) {
        self.stateStore = stateStore
        self.environment = environment
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
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
    }

    private func install(on screen: NSScreen) {
        installedScreen = screen
        panel?.close()

        let size = panelSize(for: screen)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        let frame = NSRect(origin: origin, size: size)

        let panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        let dropView = NotchDropView(frame: NSRect(origin: .zero, size: size))
        dropView.isActive = stateStore.state != .hidden
        dropView.onDrop = { items in
            Task { @MainActor in
                for item in items {
                    ShelfStore.shared.addItem(item)
                }
            }
        }

        let root = NotchRootView(
            stateStore: stateStore,
            hasNotch: screen.hasPhysicalNotch,
            notchSize: screen.effectiveNotchSize,
            menubarHeight: screen.menubarHeight
        )
        .environment(\.appEnvironment, environment)

        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            host.topAnchor.constraint(equalTo: dropView.topAnchor),
            host.bottomAnchor.constraint(equalTo: dropView.bottomAnchor)
        ])

        panel.contentView = dropView
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = true

        self.panel = panel
        self.dropView = dropView
        updateMousePassthrough()
    }

    private func updateMousePassthrough() {
        guard let panel, let dropView else { return }
        let windowPoint = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        panel.ignoresMouseEvents = dropView.hitTest(windowPoint) == nil
    }

    private func panelSize(for screen: NSScreen) -> NSSize {
        let maxWidth: CGFloat = 960
        let width = min(maxWidth, screen.frame.width - 40)
        let height: CGFloat = 520
        return NSSize(width: width, height: height)
    }

    private func observeScreenChanges() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let screen = NSScreen.preferred else { return }
                self?.install(on: screen)
                self?.refreshHoverZone()
            }
        }
    }

    private func wireHoverMonitor() {
        hoverMonitor.zoneProvider = { [weak self] in
            guard let self else { return .zero }
            return self.currentHoverZone()
        }
        hoverMonitor.onEnter = { [weak self] in
            self?.stateStore.hoverBegan()
        }
        hoverMonitor.onExit = { [weak self] in
            self?.stateStore.hoverEnded()
        }
        hoverMonitor.start()
    }

    private func refreshHoverZone() {
        // monitor pulls zone dynamically via closure
    }

    private func observeStateChanges() {
        stateCancellable = stateStore.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                self?.dropView?.isActive = newState != .hidden
                self?.panel?.ignoresMouseEvents = (newState == .hidden)
                self?.hoverMonitor.check()
            }
    }

    private func currentHoverZone() -> NSRect {
        guard let screen = installedScreen ?? NSScreen.preferred else { return .zero }
        switch stateStore.state {
        case .hidden:
            return notchHoverRect(on: screen)
        case .expanded:
            return expandedDockRect(on: screen)
        }
    }

    private func notchHoverRect(on screen: NSScreen) -> NSRect {
        let width: CGFloat
        let height: CGFloat
        if screen.hasPhysicalNotch {
            let n = screen.effectiveNotchSize
            width = n.width + 40
            height = n.height + 20
        } else {
            width = 280
            height = screen.menubarHeight + 20
        }
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func expandedDockRect(on screen: NSScreen) -> NSRect {
        let dockWidth: CGFloat = 520
        let topInset: CGFloat = screen.hasPhysicalNotch
            ? screen.effectiveNotchSize.height
            : screen.menubarHeight
        let dockHeight: CGFloat = 260 + topInset
        return NSRect(
            x: screen.frame.midX - dockWidth / 2,
            y: screen.frame.maxY - dockHeight - 8,
            width: dockWidth,
            height: dockHeight + 16
        )
    }
}
