import AppKit


protocol TangerineWheelSurface: NSView {
    init(frame: NSRect)
    var preferredSide: CGFloat { get }
    func prepare(forScreen screen: NSRect)
    var selectedOption: TangerineOption? { get }
    func apply(groups: [TangerineGroup], mode: TangerineMode, headline: String, footnote: String)
    func apply(fileURLs: [URL])
    func reset()
    @discardableResult
    func track(at point: NSPoint) -> Bool
}

enum TangerineDraggedFile {
    static func displayName(_ urls: [URL]) -> String {
        switch urls.count {
        case 0: return ""
        case 1: return urls[0].lastPathComponent
        default: return "\(urls.count) arquivos"
        }
    }

    static func icon(_ urls: [URL]) -> NSImage? {
        guard let first = urls.first else { return nil }
        return NSWorkspace.shared.icon(forFile: first.path)
    }
}

extension FloatingRadialView {
    func apply(fileURLs: [URL]) {
        setFiles(fileURLs)
    }
}

enum TangerineWheelSurfaceFactory {
    static var override: ((NSRect) -> TangerineWheelSurface)?

    static func make(frame: NSRect) -> TangerineWheelSurface {
        if let override { return override(frame) }
        return FloatingRadialView(frame: frame)
    }
}


enum TangerineInputMonitoring {
    enum Status: String, Equatable {
        case granted
        case unavailable
    }

    static var preflight: () -> Bool = { CGPreflightListenEventAccess() }

    static var status: Status { preflight() ? .granted : .unavailable }

    static var isAvailable: Bool { status == .granted }

    @discardableResult
    static func requestFromUserAction() -> Bool {
        CGRequestListenEventAccess()
    }
}

struct TangerineGestureStatus: Equatable {
    var backend: TangerineGestureBackend
    var inputMonitoring: TangerineInputMonitoring.Status

    var detectsEscape: Bool { backend.detectsEscape }

    var crossAppVerified: Bool { false }

    var summary: String {
        let base = backend == .eventMonitor
            ? "monitores de NSEvent · Esc detectável"
            : "polling sem TCC · Esc não detectável"
        return "\(base) · cross-app não verificado"
    }
}


enum TangerineGestureBackend: Equatable {
    case eventMonitor
    case polling

    static func resolve(inputMonitoring: Bool) -> TangerineGestureBackend {
        inputMonitoring ? .eventMonitor : .polling
    }

    var detectsEscape: Bool { self == .eventMonitor }

    func status(inputMonitoring: TangerineInputMonitoring.Status) -> TangerineGestureStatus {
        TangerineGestureStatus(backend: self, inputMonitoring: inputMonitoring)
    }

    func pollInterval(armed: Bool) -> TimeInterval {
        switch (self, armed) {
        case (.eventMonitor, true): return 1.0 / 60
        case (.eventMonitor, false): return 1.0 / 20
        case (.polling, true): return 1.0 / 60
        case (.polling, false): return 1.0 / 20
        }
    }

    func pollTolerance(armed: Bool) -> TimeInterval {
        let interval = pollInterval(armed: armed)
        return armed ? interval / 2 : interval
    }
}


enum TangerineWheelPlacement {
    static func screen(containing point: NSPoint, screens: [NSRect], fallback: NSRect?) -> NSRect? {
        for frame in screens where NSMouseInRect(point, frame, false) { return frame }
        if let nearest = screens.min(by: { distance(point, $0) < distance(point, $1) }) { return nearest }
        return fallback
    }

    private static func distance(_ point: NSPoint, _ frame: NSRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return hypot(dx, dy)
    }

    static func frame(center: NSPoint, side: CGFloat, screen: NSRect, margin: CGFloat = 6) -> NSRect {
        let size = max(side, 1)
        let x = clamp(center.x - size / 2, low: screen.minX + margin, high: screen.maxX - margin - size, center: screen.midX - size / 2)
        let y = clamp(center.y - size / 2, low: screen.minY + margin, high: screen.maxY - margin - size, center: screen.midY - size / 2)
        return NSRect(x: x, y: y, width: size, height: size)
    }

    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat, center: CGFloat) -> CGFloat {
        guard high >= low else { return center }
        return min(max(value, low), high)
    }
}


struct TangerineDragPolicy: Equatable {
    struct Sample: Equatable {
        var buttons: Int
        var modifiers: NSEvent.ModifierFlags
        var location: NSPoint
        var dragActive: Bool

        init(buttons: Int, modifiers: NSEvent.ModifierFlags, location: NSPoint, dragActive: Bool = false) {
            self.buttons = buttons
            self.modifiers = modifiers
            self.location = location
            self.dragActive = dragActive
        }

        var primaryDown: Bool { buttons & 1 != 0 }
        var shift: Bool { modifiers.contains(.shift) }
        var mode: TangerineMode { modifiers.contains(.option) ? .tools : .convert }
    }

    enum Reason: String, Equatable {
        case buttonReleased
        case shiftReleased
        case escape
        case dropPerformed
        case dragEnded
        case stopped
    }

    enum Effect: Equatable {
        case arm(at: NSPoint, mode: TangerineMode)
        case follow(at: NSPoint)
        case mode(TangerineMode)
        case disarm(Reason)
    }

    enum State: Equatable {
        case idle
        case candidate(origin: NSPoint, last: NSPoint, travelled: CGFloat)
        case armed(mode: TangerineMode, at: NSPoint)
    }

    static let slop: CGFloat = 5

    private(set) var state: State = .idle
    private(set) var lockedUntilRelease = false

    var isArmed: Bool { if case .armed = state { return true } else { return false } }
    var mode: TangerineMode? { if case let .armed(mode, _) = state { return mode } else { return nil } }

    mutating func observe(_ sample: Sample) -> [Effect] {
        if !sample.primaryDown {
            lockedUntilRelease = false
            return reset(reason: .buttonReleased)
        }
        if lockedUntilRelease {
            state = .idle
            return []
        }
        if !sample.shift {
            return reset(reason: .shiftReleased)
        }

        switch state {
        case .idle:
            if sample.dragActive {
                state = .armed(mode: sample.mode, at: sample.location)
                return [.arm(at: sample.location, mode: sample.mode)]
            }
            state = .candidate(origin: sample.location, last: sample.location, travelled: 0)
            return []
        case let .candidate(origin, last, travelled):
            let moved = travelled + hypot(sample.location.x - last.x, sample.location.y - last.y)
            if sample.dragActive || moved >= Self.slop {
                state = .armed(mode: sample.mode, at: sample.location)
                return [.arm(at: sample.location, mode: sample.mode)]
            }
            state = .candidate(origin: origin, last: sample.location, travelled: moved)
            return []
        case let .armed(current, point):
            let moved = sample.location != point
            guard current != sample.mode || moved else { return [] }
            state = .armed(mode: sample.mode, at: sample.location)
            var effects: [Effect] = []
            if moved { effects.append(.follow(at: sample.location)) }
            if current != sample.mode { effects.append(.mode(sample.mode)) }
            return effects
        }
    }

    mutating func escape() -> [Effect] {
        lockedUntilRelease = true
        return reset(reason: .escape)
    }

    mutating func dropPerformed() -> [Effect] {
        lockedUntilRelease = true
        return reset(reason: .dropPerformed)
    }

    mutating func dragSessionEnded() -> [Effect] {
        reset(reason: .dragEnded)
    }

    mutating func stop() -> [Effect] {
        lockedUntilRelease = false
        return reset(reason: .stopped)
    }

    private mutating func reset(reason: Reason) -> [Effect] {
        let wasArmed = isArmed
        state = .idle
        return wasArmed ? [.disarm(reason)] : []
    }


    enum DropDecision: Equatable {
        case perform
        case cancel
        case ignore
    }

    static func dropDecision(
        wheelVisible: Bool,
        fileCount: Int,
        hasSector: Bool,
        shiftHeld: Bool
    ) -> DropDecision {
        guard wheelVisible, fileCount > 0 else { return .ignore }
        guard shiftHeld, hasSector else { return .cancel }
        return .perform
    }

    static func dropOperation(armed: Bool, fileCount: Int, hasSector: Bool, shiftHeld: Bool) -> NSDragOperation {
        guard armed, shiftHeld, fileCount > 0, hasSector else { return [] }
        return .copy
    }

    static func accepts(armed: Bool, fileCount: Int, hasSector: Bool, shiftHeld: Bool) -> Bool {
        dropOperation(armed: armed, fileCount: fileCount, hasSector: hasSector, shiftHeld: shiftHeld) == .copy
    }

    func dropOperation(fileCount: Int, hasSector: Bool, shiftHeld: Bool) -> NSDragOperation {
        Self.dropOperation(armed: isArmed, fileCount: fileCount, hasSector: hasSector, shiftHeld: shiftHeld)
    }

    func accepts(fileCount: Int, hasSector: Bool, shiftHeld: Bool) -> Bool {
        dropOperation(fileCount: fileCount, hasSector: hasSector, shiftHeld: shiftHeld) == .copy
    }
}
