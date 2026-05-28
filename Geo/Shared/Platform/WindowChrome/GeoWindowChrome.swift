import SwiftUI
import AppKit

struct GeoWindowChrome: ViewModifier {
    @Binding var window: NSWindow?

    @State private var observerTokens: [NSObjectProtocol] = []

    func body(content: Content) -> some View {
        content
            .background(WindowReflection(window: $window))
            .onChange(of: window) { _, newValue in
                configureWindow(newValue)
            }
            .onDisappear {
                removeObservers()
            }
    }

    private func configureWindow(_ window: NSWindow?) {
        removeObservers()
        guard let window else { return }
        window.styleMask.remove(.titled)
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        updateWindowBackground(window)
        observeTitlebarRebuilds(window)
    }

    private func updateWindowBackground(_ window: NSWindow?) {
        guard let window else { return }
        window.backgroundColor = .clear
        window.fixTitlebarBackground()
    }

    private func observeTitlebarRebuilds(_ window: NSWindow) {
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { _ in
                window.fixTitlebarBackground()
            }
            observerTokens.append(token)
        }
    }

    private func removeObservers() {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
    }
}

extension View {
    func geoWindowChrome(window: Binding<NSWindow?>) -> some View {
        modifier(GeoWindowChrome(window: window))
    }
}
