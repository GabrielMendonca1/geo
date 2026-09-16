import AppKit
import CoreGraphics

final class TangerineDragMonitor {
    private(set) var policy = TangerineDragPolicy()
    private var monitors: [Any] = []
    private var timer: Timer?
    private var sawRealDrag = false
    private var running = false

    var onEffects: (([TangerineDragPolicy.Effect]) -> Void)?

    var inputMonitoringProbe: () -> TangerineInputMonitoring.Status = { TangerineInputMonitoring.status }

    private(set) var backend: TangerineGestureBackend = .polling
    private(set) var inputMonitoring: TangerineInputMonitoring.Status = .unavailable

    struct RawInput: Equatable {
        var buttons: Int
        var modifiers: NSEvent.ModifierFlags
        var location: NSPoint
    }

    var rawInput: () -> RawInput = {
        RawInput(
            buttons: NSEvent.pressedMouseButtons,
            modifiers: NSEvent.modifierFlags,
            location: NSEvent.mouseLocation
        )
    }

    var hasLiveDragSession: Bool { sawRealDrag }

    var status: TangerineGestureStatus {
        backend.status(inputMonitoring: inputMonitoring)
    }

    var isArmed: Bool { policy.isArmed }

    func start() {
        guard !running else { return }
        running = true
        inputMonitoring = inputMonitoringProbe()
        backend = TangerineGestureBackend.resolve(inputMonitoring: inputMonitoring == .granted)
        installMonitors()
        schedule()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        sawRealDrag = false
        emit(policy.stop())
    }

    func noteLiveDragSession() {
        sawRealDrag = true
    }

    func noteDropPerformed() {
        sawRealDrag = false
        emit(policy.dropPerformed())
    }

    func noteDragSessionEnded() {
        sawRealDrag = false
        emit(policy.dragSessionEnded())
    }

    func clearLiveDragSession() {
        sawRealDrag = false
    }

    func noteEscape() {
        emit(policy.escape())
    }


    private static let escapeKeyCode: UInt16 = 53

    private func installMonitors() {
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == Self.escapeKeyCode {
                self.noteEscape()
            } else {
                self.pump()
            }
            return event
        }
        monitors = [local].compactMap { $0 }
        guard backend == .eventMonitor else { return }
        let mouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown]) {
            [weak self] event in
            guard let self else { return }
            switch event.type {
            case .leftMouseDragged: self.sawRealDrag = true
            case .leftMouseUp: self.sawRealDrag = false
            default: break
            }
            self.pump()
        }
        let flags = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] _ in self?.pump() }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            if event.keyCode == Self.escapeKeyCode { self.noteEscape() } else { self.pump() }
        }
        monitors.append(contentsOf: [mouse, flags, keys].compactMap { $0 })
    }

    private func schedule() {
        let armed = policy.isArmed
        let interval = backend.pollInterval(armed: armed)
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.pump() }
        timer.tolerance = backend.pollTolerance(armed: armed)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pump() {
        guard running else { return }
        let wasArmed = policy.isArmed
        let raw = rawInput()
        if raw.buttons & 1 == 0 { sawRealDrag = false }
        let sample = TangerineDragPolicy.Sample(
            buttons: raw.buttons,
            modifiers: raw.modifiers,
            location: raw.location,
            dragActive: sawRealDrag
        )
        emit(policy.observe(sample))
        if policy.isArmed != wasArmed { schedule() }
    }

    func pumpOnce() {
        pump()
    }

    func feed(_ sample: TangerineDragPolicy.Sample) {
        emit(policy.observe(sample))
    }

    private func emit(_ effects: [TangerineDragPolicy.Effect]) {
        guard !effects.isEmpty else { return }
        onEffects?(effects)
    }
}

final class FinderDragOverlay {
    private let panel: NSPanel
    private let root: DropView
    private let surface: TangerineWheelSurface
    private let monitor = TangerineDragMonitor()

    var wheel: TangerineWheelSurface { surface }

    private(set) var urls: [URL] = []
    private(set) var mode: TangerineMode = .convert
    private(set) var isVisible = false
    private(set) var isWheelVisible = false
    private var lastScreen: NSRect = .zero
    private var armPoint: NSPoint = .zero
    private var didLogFileURLHandshake = false
    private var didLogDropDecision = false
    private(set) var lastDropDecision: TangerineDragPolicy.DropDecision?

    static let probeSide: CGFloat = 24

    var provideGroups: (([URL], TangerineMode) -> (groups: [TangerineGroup], headline: String)?)?
    var commit: (([URL], TangerineOption) -> Void)?

    var modifierProvider: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    var screenProvider: () -> [NSRect] = { NSScreen.screens.map(\.frame) }

    var backend: TangerineGestureBackend { monitor.backend }
    var status: TangerineGestureStatus { monitor.status }
    var inputMonitoring: TangerineInputMonitoring.Status { monitor.inputMonitoring }

    @discardableResult
    func requestInputMonitoringFromUserAction() -> Bool {
        TangerineInputMonitoring.requestFromUserAction()
    }

    var dragScreenPoint: ((NSDraggingInfo) -> NSPoint)?

    init() {
        surface = TangerineWheelSurfaceFactory.make(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        let side = max(surface.preferredSide, 120)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .aqua)

        root = DropView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        root.autoresizingMask = [.width, .height]
        panel.contentView = root
        surface.frame = root.bounds
        surface.autoresizingMask = [.width, .height]
        surface.isHidden = true
        root.addSubview(surface)
        root.registerForDraggedTypes([.fileURL])

        root.onEntered = { [weak self] info in self?.handleEntered(info) ?? [] }
        root.onUpdated = { [weak self] info in self?.handleUpdated(info) ?? [] }
        root.onExited = { [weak self] in self?.handleExited() }
        root.onPerform = { [weak self] info in self?.handlePerform(info) ?? false }
        root.onEnded = { [weak self] in self?.monitor.noteDragSessionEnded() }
        root.canAccept = { [weak self] info in self?.handleAccept(info) ?? false }

        dragScreenPoint = { [weak panel] info in
            panel?.convertPoint(toScreen: info.draggingLocation) ?? info.draggingLocation
        }
    }

    func start() {
        monitor.onEffects = { [weak self] effects in self?.apply(effects) }
        monitor.start()
    }

    func stop() {
        monitor.stop()
        hide()
    }


    func apply(_ effects: [TangerineDragPolicy.Effect]) {
        for effect in effects {
            switch effect {
            case let .arm(point, mode):
                show(at: point, mode: mode)
            case let .follow(point):
                follow(to: point)
            case let .mode(mode):
                setMode(mode)
            case .disarm:
                hide()
            }
        }
    }

    func show(at point: NSPoint, mode: TangerineMode) {
        guard let screen = screen(for: point) else { return }
        lastScreen = screen
        armPoint = point
        self.mode = mode
        urls = []
        isWheelVisible = false
        didLogFileURLHandshake = false
        didLogDropDecision = false
        lastDropDecision = nil
        surface.isHidden = true
        surface.apply(groups: [], mode: mode, headline: "", footnote: "")
        surface.reset()
        surface.apply(fileURLs: [])
        panel.setFrame(
            TangerineWheelPlacement.frame(center: point, side: Self.probeSide, screen: screen),
            display: false
        )
        panel.orderFrontRegardless()
        isVisible = true
    }

    private func follow(to point: NSPoint) {
        guard isVisible, !isWheelVisible else { return }
        guard let screen = screen(for: point) else { return }
        lastScreen = screen
        armPoint = point
        panel.setFrame(
            TangerineWheelPlacement.frame(center: point, side: Self.probeSide, screen: screen),
            display: false
        )
    }

    private func revealWheel(around point: NSPoint) {
        guard !isWheelVisible else { return }
        let screen = screen(for: point) ?? lastScreen
        surface.prepare(forScreen: screen)
        let side = max(surface.preferredSide, 120)
        lastScreen = screen
        armPoint = point
        panel.setFrame(TangerineWheelPlacement.frame(center: point, side: side, screen: screen), display: false)
        surface.frame = root.bounds
        surface.isHidden = false
        isWheelVisible = true
        panel.orderFrontRegardless()
    }

    private func screen(for point: NSPoint) -> NSRect? {
        TangerineWheelPlacement.screen(
            containing: point,
            screens: screenProvider(),
            fallback: NSScreen.main?.frame
        )
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        isWheelVisible = false
        urls = []
        surface.isHidden = true
        surface.reset()
        surface.apply(fileURLs: [])
        surface.apply(groups: [], mode: mode, headline: "", footnote: "")
        panel.orderOut(nil)
        monitor.clearLiveDragSession()
    }

    private func setMode(_ next: TangerineMode) {
        guard next != mode else { return }
        mode = next
        refreshGroups()
    }

    private func refreshGroups() {
        guard !urls.isEmpty, let supply = provideGroups?(urls, mode), !supply.groups.isEmpty else {
            surface.apply(groups: [], mode: mode, headline: "", footnote: "")
            surface.apply(fileURLs: [])
            surface.reset()
            return
        }
        surface.apply(fileURLs: urls)
        surface.apply(
            groups: supply.groups,
            mode: mode,
            headline: supply.headline,
            footnote: mode == .convert
                ? "solte no formato · segure ⌥ para ferramentas"
                : "solte na ferramenta · solte o ⌥ para converter"
        )
    }


    func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL] ?? []).filter { $0.isFileURL }
    }

    private var shiftHeld: Bool { modifierProvider().contains(.shift) }

    func handleEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        monitor.noteLiveDragSession()
        guard isVisible, shiftHeld else { return [] }
        urls = fileURLs(info)
        guard !urls.isEmpty else { return [] }
        mode = modifierProvider().contains(.option) ? .tools : .convert
        if !didLogFileURLHandshake {
            didLogFileURLHandshake = true
            NSLog("Tangerine drag: fileURLs=%ld mode=%@ handshake=true", urls.count, String(describing: mode))
        }
        let wasHidden = !isWheelVisible
        revealWheel(around: dragScreenPoint?(info) ?? armPoint)
        refreshGroups()
        if wasHidden {
            surface.reset()
            return []
        }
        return operation(info)
    }

    func handleUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        guard isVisible, isWheelVisible, !urls.isEmpty else { return [] }
        guard shiftHeld else {
            hide()
            return []
        }
        setMode(modifierProvider().contains(.option) ? .tools : .convert)
        return operation(info)
    }

    func handleExited() {
        surface.reset()
    }

    func handleAccept(_ info: NSDraggingInfo) -> Bool {
        let decision = decision(info)
        let accepted = decision == .perform
        if decision == .cancel { cancelDrop() }
        if !urls.isEmpty, didLogFileURLHandshake, !didLogDropDecision {
            didLogDropDecision = true
            NSLog(
                "Tangerine drag: fileURLs=%ld mode=%@ accepted=%@",
                urls.count,
                String(describing: mode),
                accepted ? "true" : "false"
            )
        }
        return accepted
    }

    func handlePerform(_ info: NSDraggingInfo) -> Bool {
        guard isVisible, isWheelVisible, !urls.isEmpty else { return false }
        guard decision(info) == .perform, let option = surface.selectedOption else {
            cancelDrop()
            return false
        }
        let files = urls
        monitor.noteDropPerformed()
        hide()
        commit?(files, option)
        return true
    }

    @discardableResult
    private func track(_ info: NSDraggingInfo) -> Bool {
        guard isWheelVisible else { return false }
        let inRoot = root.convert(info.draggingLocation, from: nil)
        return surface.track(at: surface.convert(inRoot, from: root))
    }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        let sector = track(info)
        return TangerineDragPolicy.dropOperation(
            armed: isWheelVisible,
            fileCount: urls.count,
            hasSector: sector,
            shiftHeld: shiftHeld
        )
    }

    private func decision(_ info: NSDraggingInfo) -> TangerineDragPolicy.DropDecision {
        let sector = track(info)
        let decision = TangerineDragPolicy.dropDecision(
            wheelVisible: isWheelVisible,
            fileCount: urls.count,
            hasSector: sector,
            shiftHeld: shiftHeld
        )
        if isWheelVisible { lastDropDecision = decision }
        return decision
    }

    private func cancelDrop() {
        guard isWheelVisible else { return }
        lastDropDecision = .cancel
        monitor.noteDropPerformed()
        hide()
    }
}

final class DropView: NSView {
    var onEntered: ((NSDraggingInfo) -> NSDragOperation)?
    var onUpdated: ((NSDraggingInfo) -> NSDragOperation)?
    var onExited: (() -> Void)?
    var onPerform: ((NSDraggingInfo) -> Bool)?
    var onEnded: (() -> Void)?
    var canAccept: ((NSDraggingInfo) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onEntered?(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onUpdated?(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAccept?(sender) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerform?(sender) ?? false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onEnded?()
    }
}
