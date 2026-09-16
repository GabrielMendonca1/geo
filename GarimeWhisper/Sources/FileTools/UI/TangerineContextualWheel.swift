import AppKit

protocol TangerineContextualSurface: TangerineWheelSurface {
    var contextualOptionCount: Int { get }
    func contextualHitIndex(at point: NSPoint) -> Int?
    func contextualFocus(index: Int?)
    func contextualOption(at index: Int) -> TangerineOption?
}

extension FloatingRadialView: TangerineContextualSurface {
    var contextualOptionCount: Int { options.count }

    func contextualHitIndex(at point: NSPoint) -> Int? {
        if case let .sector(index) = hit(at: point) { return index }
        return nil
    }

    func contextualFocus(index: Int?) {
        guard let index, let midpoint = sectorMidpoint(index) else {
            clearSelection()
            return
        }
        track(at: midpoint)
    }

    func contextualOption(at index: Int) -> TangerineOption? {
        options.indices.contains(index) ? options[index] : nil
    }
}

struct TangerineContextualInvocation: Equatable {
    let id: UUID
    let urls: [URL]
    let mode: TangerineMode
    let sourcePID: pid_t
    let anchor: NSPoint
    let groups: [TangerineGroup]
    let headline: String

    init(
        id: UUID = UUID(),
        urls: [URL],
        mode: TangerineMode,
        sourcePID: pid_t,
        anchor: NSPoint,
        groups: [TangerineGroup],
        headline: String
    ) {
        self.id = id
        self.urls = urls
        self.mode = mode
        self.sourcePID = sourcePID
        self.anchor = anchor
        self.groups = groups
        self.headline = headline
    }

    static func == (lhs: TangerineContextualInvocation, rhs: TangerineContextualInvocation) -> Bool {
        lhs.id == rhs.id
    }
}

protocol TangerineContextualPresenting: AnyObject {
    var onCommit: ((UUID, TangerineOption) -> Void)? { get set }
    var onDismiss: ((UUID, TangerineContextualDismissReason) -> Void)? { get set }
    var activeSessionID: UUID? { get }
    var keyboardDiagnosticSummary: String? { get }
    @discardableResult func present(_ invocation: TangerineContextualInvocation) -> Bool
    func dismiss(reason: TangerineContextualDismissReason)
}

extension TangerineContextualPresenting {
    var keyboardDiagnosticSummary: String? { nil }
}

struct TangerineContextualKeyDiagnostics: Equatable {
    var presentations = 0
    var keyAcquisitions = 0
    var presentationsWithoutKey = 0
    var keysDelivered = 0

    var summary: String {
        "aberturas \(presentations) · virou key \(keyAcquisitions) · sem key \(presentationsWithoutKey) · teclas \(keysDelivered)"
    }
}

final class TangerineContextualWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TangerineContextualRootView: NSView {
    var onHover: ((NSPoint) -> Void)?
    var onClick: ((NSPoint) -> Void)?
    var onKey: ((TangerineContextualKey) -> Void)?

    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onKey?(.escape)
        case 36, 76: onKey?(.enter)
        case 123, 126: onKey?(.arrow(.previous))
        case 124, 125: onKey?(.arrow(.next))
        default: super.keyDown(with: event)
        }
    }
}

final class TangerineContextualPanel: NSObject, TangerineContextualPresenting, NSWindowDelegate {
    var onCommit: ((UUID, TangerineOption) -> Void)?
    var onDismiss: ((UUID, TangerineContextualDismissReason) -> Void)?

    var screenProvider: () -> [NSRect] = { NSScreen.screens.map(\.frame) }
    var fallbackScreen: () -> NSRect? = { NSScreen.main?.frame }

    private let panel: TangerineContextualWindow
    private let root: TangerineContextualRootView
    private let surface: TangerineContextualSurface
    private var policy = TangerineContextualPolicy()
    private var invocation: TangerineContextualInvocation?
    private var becameKey = false

    private(set) var isVisible = false
    private(set) var keyDiagnostics = TangerineContextualKeyDiagnostics()

    var diagnosticLog: (String) -> Void = { NSLog("%@", $0) }

    var activeSessionID: UUID? { policy.activeSessionID }

    var keyboardDiagnosticSummary: String? { keyDiagnostics.summary }

    var tracksMouseMoved: Bool { panel.acceptsMouseMovedEvents }

    var wheel: TangerineContextualSurface { surface }

    init(surfaceFactory: (NSRect) -> TangerineContextualSurface = { FloatingRadialView(frame: $0) }) {
        let frame = NSRect(x: 0, y: 0, width: 480, height: 480)
        surface = surfaceFactory(frame)
        let side = max(surface.preferredSide, 120)
        panel = TangerineContextualWindow(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        root = TangerineContextualRootView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .aqua)
        panel.delegate = self

        root.autoresizingMask = [.width, .height]
        panel.contentView = root
        surface.frame = root.bounds
        surface.autoresizingMask = [.width, .height]
        root.addSubview(surface)

        root.onHover = { [weak self] point in self?.handleHover(at: point) }
        root.onClick = { [weak self] point in self?.handleClick(at: point) }
        root.onKey = { [weak self] key in self?.handleKey(key) }
    }

    @discardableResult
    func present(_ next: TangerineContextualInvocation) -> Bool {
        if policy.isPresenting { dismiss(reason: .reinvoked) }
        guard !next.urls.isEmpty, !next.groups.isEmpty else {
            clearSurface(mode: next.mode)
            return false
        }
        let screen = TangerineWheelPlacement.screen(
            containing: next.anchor,
            screens: screenProvider(),
            fallback: fallbackScreen()
        )
        guard let screen else { return false }
        surface.prepare(forScreen: screen)
        surface.apply(fileURLs: next.urls)
        surface.apply(
            groups: next.groups,
            mode: next.mode,
            headline: next.headline,
            footnote: next.mode == .convert ? "clique no formato · Esc cancela" : "clique na ferramenta · Esc cancela"
        )
        surface.reset()
        guard surface.contextualOptionCount > 0 else {
            clearSurface(mode: next.mode)
            return false
        }
        let side = max(surface.preferredSide, 120)
        panel.setFrame(
            TangerineWheelPlacement.frame(center: next.anchor, side: side, screen: screen),
            display: false
        )
        surface.frame = root.bounds
        surface.isHidden = false
        invocation = next
        let session = TangerineContextualPolicy.Session(
            id: next.id,
            sourcePID: next.sourcePID,
            fileKeys: TangerineContextualFileKeys.keys(next.urls),
            optionCount: surface.contextualOptionCount
        )
        apply(policy.apply(.present(session)))
        isVisible = true
        becameKey = false
        keyDiagnostics.presentations += 1
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(root)
        return true
    }

    func dismiss(reason: TangerineContextualDismissReason) {
        let effects = policy.apply(.invalidate(reason))
        apply(effects)
        guard isVisible else { return }
        hide()
    }

    func handleHover(at point: NSPoint) {
        guard policy.isPresenting else { return }
        apply(policy.apply(.hover(index(at: point))))
    }

    func handleClick(at point: NSPoint) {
        guard policy.isPresenting else { return }
        apply(policy.apply(.click(index(at: point))))
    }

    func handleKey(_ key: TangerineContextualKey) {
        guard policy.isPresenting else { return }
        keyDiagnostics.keysDelivered += 1
        switch key {
        case .escape: apply(policy.apply(.escape))
        case .enter: apply(policy.apply(.enter))
        case let .arrow(direction): apply(policy.apply(.arrow(direction)))
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        becameKey = true
        keyDiagnostics.keyAcquisitions += 1
        diagnosticLog("tangerine.wheel key=sim \(keyDiagnostics.summary)")
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, becameKey, policy.isPresenting else { return }
        dismiss(reason: .sourceChanged)
    }

    private func index(at point: NSPoint) -> Int? {
        let local = surface.convert(point, from: root)
        return surface.contextualHitIndex(at: local)
    }

    private func apply(_ effects: [TangerineContextualPolicy.Effect]) {
        for effect in effects {
            switch effect {
            case let .select(index):
                surface.contextualFocus(index: index)
            case let .commit(sessionID, index):
                guard let option = surface.contextualOption(at: index) else {
                    hide()
                    onDismiss?(sessionID, .selectionChanged)
                    continue
                }
                hide()
                onCommit?(sessionID, option)
            case let .dismiss(reason):
                let sessionID = invocation?.id
                hide()
                if let sessionID { onDismiss?(sessionID, reason) }
            }
        }
    }

    private func hide() {
        guard isVisible else { return }
        isVisible = false
        if !becameKey {
            keyDiagnostics.presentationsWithoutKey += 1
            diagnosticLog("tangerine.wheel key=nao \(keyDiagnostics.summary)")
        }
        becameKey = false
        let mode = invocation?.mode ?? .convert
        invocation = nil
        surface.isHidden = true
        clearSurface(mode: mode)
        panel.orderOut(nil)
    }

    private func clearSurface(mode: TangerineMode) {
        surface.reset()
        surface.apply(fileURLs: [])
        surface.apply(groups: [], mode: mode, headline: "", footnote: "")
    }
}

final class TangerineContextualNoticeButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class TangerineContextualNoticePanel {
    private let panel: NSPanel
    private let card = TangerineCard(frame: NSRect(x: 0, y: 0, width: 360, height: 96))
    private let title = TangerineTheme.label("", size: 12.5, weight: .semibold)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let action = TangerineContextualNoticeButton(title: "", target: nil, action: nil)

    var actionAcceptsFirstMouse: Bool { action.acceptsFirstMouse(for: nil) }

    var isActionVisible: Bool { !action.isHidden }
    private var hideWork: DispatchWorkItem?
    private var grant: (() -> Void)?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .aqua)

        card.autoresizingMask = [.width, .height]
        panel.contentView = card
        title.frame = NSRect(x: 16, y: 12, width: 328, height: 18)
        message.frame = NSRect(x: 16, y: 32, width: 328, height: 34)
        message.font = .systemFont(ofSize: 11)
        message.textColor = TangerineTheme.inkSoft
        message.maximumNumberOfLines = 3
        message.lineBreakMode = .byTruncatingTail
        message.isEditable = false
        message.isSelectable = false
        message.drawsBackground = false
        message.isBezeled = false
        action.frame = NSRect(x: 16, y: 66, width: 240, height: 24)
        action.bezelStyle = .rounded
        action.font = .systemFont(ofSize: 11)
        action.target = self
        action.action = #selector(grantPressed)
        action.isHidden = true
        card.addSubview(title)
        card.addSubview(message)
        card.addSubview(action)
    }

    func show(_ notice: TangerineContextualNotice, at anchor: NSPoint, onGrant: (() -> Void)?) {
        title.stringValue = notice.title
        message.stringValue = notice.message
        grant = onGrant
        if let actionTitle = notice.actionTitle, onGrant != nil {
            action.title = actionTitle
            action.isHidden = false
        } else {
            action.isHidden = true
        }
        let screens = NSScreen.screens.map(\.frame)
        let screen = TangerineWheelPlacement.screen(
            containing: anchor,
            screens: screens,
            fallback: NSScreen.main?.frame
        ) ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 360, height: 96)
        let origin = NSPoint(
            x: min(max(anchor.x - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8),
            y: min(max(anchor.y - size.height - 12, screen.minY + 8), screen.maxY - size.height - 8)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (action.isHidden ? 4 : 9), execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        grant = nil
        panel.orderOut(nil)
    }

    @objc private func grantPressed() {
        let handler = grant
        hide()
        handler?()
    }
}
