import AppKit

enum HubAction: Equatable {
    case dictate
    case sounds
    case quit
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    convenience init(frame: NSRect, handler: @escaping () -> Void) {
        self.init(frame: frame)
        self.handler = handler
        target = self
        action = #selector(fire)
    }

    @objc private func fire() {
        handler?()
    }
}

enum HubPanelView {
    static func build(status: String, dictationTitle: String, onAction: @escaping (HubAction) -> Void) -> NSView {
        let width = Config.panelWidth
        let inset = Config.panelInset
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 150))
        let label = NSTextField(labelWithString: status)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: inset, y: 14, width: width - inset * 2, height: 20)
        container.addSubview(label)
        let actions: [(HubAction, String)] = [(.dictate, dictationTitle), (.sounds, "Sons…"), (.quit, "Sair")]
        for (index, entry) in actions.enumerated() {
            let button = ClosureButton(frame: NSRect(x: inset, y: CGFloat(40 + index * 34), width: width - inset * 2, height: 28)) {
                onAction(entry.0)
            }
            button.title = entry.1
            button.bezelStyle = .rounded
            container.addSubview(button)
        }
        return container
    }
}

final class HubPanel {
    private let popover = NSPopover()
    private let host = NSViewController()

    var isOpen: Bool { popover.isShown }

    init() {
        host.view = FlippedView(frame: NSRect(x: 0, y: 0, width: Config.panelWidth, height: 10))
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
    }

    static func availableHeight(anchorBottom: CGFloat, screenBottom: CGFloat) -> CGFloat {
        max(120, anchorBottom - screenBottom - Config.panelGap - 8)
    }

    private func fit(_ content: NSView, below button: NSStatusBarButton?) -> NSView {
        guard let button, let window = button.window else { return content }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let ceiling = HubPanel.availableHeight(anchorBottom: anchor.minY, screenBottom: visible.minY)
        guard content.frame.height > ceiling else { return content }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: content.frame.width, height: ceiling))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = content
        content.frame.origin = .zero
        return scroll
    }

    func show(content raw: NSView, below button: NSStatusBarButton?) {
        let content = fit(raw, below: button)
        let size = content.frame.size
        let stage = FlippedView(frame: NSRect(origin: .zero, size: size))
        content.frame.origin = .zero
        content.autoresizingMask = [.width, .height]
        stage.addSubview(content)
        host.view = stage
        popover.contentSize = size
        guard let button else { return }
        if popover.isShown {
            popover.contentViewController?.view.needsLayout = true
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }
}
