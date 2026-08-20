import AppKit

final class StatusIcon: NSObject {
    private let item: NSStatusItem
    private var timer: Timer?
    private var followUp: DispatchWorkItem?
    private var motionObserver: NSObjectProtocol?
    private var symbolCache: [String: NSImage] = [:]

    private var state: IconState = .idle
    private var overlays: Set<IconOverlay> = []
    private var flashSymbol: String?
    private var flashReset: DispatchWorkItem?
    private var plan: IconPlan
    private var frameIndex = 0
    private var level: Float = 0
    private var peak: Float = 0
    private var lastLevelDraw = Date.distantPast

    let menu = NSMenu()

    private static let side: CGFloat = 21
    private static let dots = DotMatrix.triangle()

    var onPrimaryClick: (() -> Void)?

    var button: NSStatusBarButton? { item.button }

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        plan = IconAnimation.plan(for: .idle, reduceMotion: false)
        super.init()
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        observeMotion()
        apply(.idle)
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popUpActions()
            return
        }
        onPrimaryClick?()
    }

    func popUpActions() {
        guard let button = item.button else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    deinit {
        timer?.invalidate()
        followUp?.cancel()
        flashReset?.cancel()
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
        }
    }

    var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var renderedImage: NSImage? { item.button?.image }

    var isAnimating: Bool { timer != nil }

    var isFlashing: Bool { flashSymbol != nil }

    var activeOverlays: Set<IconOverlay> { overlays }

    func apply(_ next: IconState) {
        timer?.invalidate()
        timer = nil
        followUp?.cancel()
        followUp = nil

        state = next
        plan = effectivePlan()
        frameIndex = 0
        if plan.levelDriven {
            lastLevelDraw = .distantPast
        } else {
            level = 0
            peak = 0
        }
        render()
        scheduleTicker()
        scheduleFollowUp()
    }

    func setOverlay(_ overlay: IconOverlay, enabled: Bool) {
        let changed = enabled
            ? overlays.insert(overlay).inserted
            : overlays.remove(overlay) != nil
        guard changed else { return }
        refreshPlan()
    }

    private func refreshPlan() {
        timer?.invalidate()
        timer = nil
        plan = effectivePlan()
        frameIndex = 0
        render()
        scheduleTicker()
    }

    private func effectivePlan() -> IconPlan {
        if state == .idle, overlays.contains(.awake) {
            return IconAnimation.awakePlan(reduceMotion: reduceMotion)
        }
        return IconAnimation.plan(for: state, reduceMotion: reduceMotion)
    }

    func flash(_ symbolName: String) {
        flashSymbol = symbolName
        flashReset?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flashSymbol = nil
            self.flashReset = nil
            self.render()
        }
        flashReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.iconFlashSeconds, execute: work)
        render()
    }

    func updateLevel(_ value: Float, peak peakValue: Float) {
        guard plan.levelDriven else { return }
        level = value
        peak = peakValue
        let now = Date()
        guard now.timeIntervalSince(lastLevelDraw) >= plan.minimumRedrawInterval else { return }
        lastLevelDraw = now
        render()
    }

    private func scheduleTicker() {
        guard plan.isAnimated else { return }
        let ticker = Timer(timeInterval: plan.interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameIndex += 1
            if !self.plan.repeats, self.frameIndex >= self.plan.frameCount {
                self.frameIndex = self.plan.frameCount - 1
                self.timer?.invalidate()
                self.timer = nil
            }
            self.render()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    private func scheduleFollowUp() {
        guard let next = plan.followUp else { return }
        let work = DispatchWorkItem { [weak self] in self?.apply(next) }
        followUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.followUpDelay, execute: work)
    }

    private func render() {
        guard let button = item.button else { return }
        let base: NSImage?
        if let flashSymbol {
            base = symbol(flashSymbol)
        } else {
            switch plan.render {
            case .symbol(let name):
                base = tinted(symbol(name))
            case .triangle:
                base = drawTriangle()
            case .triangleLevel:
                base = drawMatrix(DotMatrix.level(StatusIcon.dots, level: level, peak: peak))
            case .triangleBeat:
                base = drawMatrix(
                    DotMatrix.wave(StatusIcon.dots, frame: frameIndex, frameCount: plan.frameCount)
                )
            case .triangleJump:
                base = drawMatrix(
                    DotMatrix.steady(StatusIcon.dots),
                    lift: IconAnimation.jumpOffset(frame: frameIndex, frameCount: plan.frameCount)
                )
            case .triangleSweep:
                base = drawTriangleSweep()
            case .spinner:
                base = drawSpinner()
            case .blocked:
                base = drawBlocked()
            }
        }
        if let image = composed(base) {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = fallbackGlyph
        }
    }

    private var fallbackGlyph: String {
        switch state {
        case .idle: return "○"
        case .starting, .listening, .recording: return "●"
        case .transcribing, .flushing: return "◐"
        case .meeting: return "◉"
        case .success: return "✓"
        case .error: return "!"
        case .cancelled: return "×"
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: "garime whisper") else {
            return nil
        }
        image.isTemplate = true
        symbolCache[name] = image
        return image
    }

    private func composed(_ base: NSImage?) -> NSImage? {
        guard let base else { return nil }
        guard !overlays.isEmpty else { return base }
        let active = overlays
        let moon: NSImage? = nil
        let size = NSSize(width: StatusIcon.side, height: StatusIcon.side)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            base.draw(in: rect)
            if let moon {
                let corner = NSRect(x: rect.maxX - 8, y: rect.minY, width: 8, height: 8)
                StatusIcon.punch(corner)
                moon.draw(in: corner)
            }
            if active.contains(.alert) {
                let corner = NSRect(x: rect.maxX - 6.5, y: rect.maxY - 6.5, width: 6.5, height: 6.5)
                StatusIcon.punch(corner)
                NSBezierPath(ovalIn: corner).fill()
            }
            return true
        }
        image.isTemplate = base.isTemplate
        image.accessibilityDescription = "garime whisper"
        return image
    }

    private static func punch(_ rect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let previous = context.compositingOperation
        context.compositingOperation = .destinationOut
        NSBezierPath(ovalIn: rect.insetBy(dx: -1.3, dy: -1.3)).fill()
        context.compositingOperation = previous
    }

    private func canvas(tint: IconTint = .neutral, _ handler: @escaping (NSRect) -> Void) -> NSImage {
        let size = NSSize(width: StatusIcon.side, height: StatusIcon.side)
        let paint = StatusIcon.color(for: tint)
        let image = NSImage(size: size, flipped: false) { rect in
            (paint ?? NSColor.black).setFill()
            (paint ?? NSColor.black).setStroke()
            handler(rect)
            return true
        }
        image.isTemplate = paint == nil
        image.accessibilityDescription = "garime whisper"
        return image
    }

    static func color(for tint: IconTint) -> NSColor? {
        switch tint {
        case .neutral: return nil
        case .live: return NSColor(srgbRed: 1.0, green: 0.15, blue: 0.20, alpha: 1)
        case .work: return NSColor(srgbRed: 1.0, green: 0.55, blue: 0.0, alpha: 1)
        case .good: return NSColor(srgbRed: 0.10, green: 0.90, blue: 0.35, alpha: 1)
        case .warn: return NSColor(srgbRed: 1.0, green: 0.83, blue: 0.0, alpha: 1)
        case .awake: return NSColor(srgbRed: 1.0, green: 0.45, blue: 0.0, alpha: 1)
        }
    }

    private func tinted(_ image: NSImage?) -> NSImage? {
        guard let image, let color = StatusIcon.color(for: plan.tint) else { return image }
        let painted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        painted.isTemplate = false
        painted.accessibilityDescription = "garime whisper"
        return painted
    }

    private static func dotRect(_ dot: MatrixDot, in rect: NSRect, radius: CGFloat) -> NSRect {
        let inset = Config.iconTriangleInset
        let box = NSRect(
            x: rect.minX + inset / 2 + radius,
            y: rect.minY + inset / 2 + radius,
            width: rect.width - inset - radius * 2,
            height: rect.height - inset - radius * 2
        )
        let x = box.minX + CGFloat(dot.x) * box.width
        let y = box.maxY - CGFloat(dot.y) * box.height
        return NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
    }

    private func drawMatrix(_ brightness: [Double], scale: Double = 1, lift: Double = 0) -> NSImage {
        let dots = StatusIcon.dots
        let paint = StatusIcon.color(for: plan.tint) ?? NSColor.black
        return canvas(tint: plan.tint) { rect in
            let radius = Config.iconDotRadius * CGFloat(scale)
            for (index, dot) in dots.enumerated() {
                let value = index < brightness.count ? brightness[index] : 1
                guard value > 0.02 else { continue }
                paint.withAlphaComponent(CGFloat(min(1, max(0, value)))).setFill()
                var box = StatusIcon.dotRect(dot, in: rect, radius: radius)
                box.origin.y += CGFloat(lift) * Config.iconJumpLift
                NSBezierPath(ovalIn: box).fill()
            }
        }
    }

    private func drawTriangle(scale: Double = 1) -> NSImage {
        let cacheable = plan.tint == .neutral && scale == 1
        if cacheable, let cached = symbolCache["__triangle"] { return cached }
        let image = drawMatrix(DotMatrix.steady(StatusIcon.dots), scale: scale)
        if cacheable { symbolCache["__triangle"] = image }
        return image
    }

    private func drawTriangleSweep() -> NSImage {
        drawMatrix(DotMatrix.chase(StatusIcon.dots, frame: frameIndex, frameCount: plan.frameCount))
    }

    private func drawSpinner() -> NSImage {
        let count = max(1, plan.frameCount)
        let progress = CGFloat(frameIndex % count) / CGFloat(count)
        return canvas { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6
            let arc = NSBezierPath()
            let start = progress * 360
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: start,
                endAngle: start + 260
            )
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            arc.stroke()
        }
    }

    private func drawBlocked() -> NSImage {
        canvas { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6
            let ring = NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            ring.lineWidth = 1.6
            ring.stroke()

            let slash = NSBezierPath()
            let offset = radius * 0.62
            slash.move(to: NSPoint(x: center.x - offset, y: center.y - offset))
            slash.line(to: NSPoint(x: center.x + offset, y: center.y + offset))
            slash.lineWidth = 1.6
            slash.lineCapStyle = .round
            slash.stroke()
        }
    }

    private func observeMotion() {
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.apply(self.state)
        }
    }
}
