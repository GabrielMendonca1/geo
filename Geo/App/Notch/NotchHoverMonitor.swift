import AppKit

@MainActor
final class NotchHoverMonitor {
    var zoneProvider: () -> NSRect = { .zero }
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pollTimer: Timer?
    private var isInside = false

    func start() {
        stop()
        let localHandler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.check()
            return event
        }
        let globalHandler: (NSEvent) -> Void = { [weak self] _ in
            self?.check()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged],
            handler: localHandler
        )
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged],
            handler: globalHandler
        )
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.check()
            }
        }
        check()
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        pollTimer?.invalidate()
        localMonitor = nil
        globalMonitor = nil
        pollTimer = nil
        isInside = false
    }

    func check() {
        let location = NSEvent.mouseLocation
        let zone = zoneProvider()
        let inside = zone.contains(location)
        if inside != isInside {
            isInside = inside
            if inside { onEnter() } else { onExit() }
        }
    }
}
