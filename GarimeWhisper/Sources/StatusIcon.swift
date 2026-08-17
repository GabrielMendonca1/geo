import AppKit

final class StatusIcon {
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

    private static let side: CGFloat = 18

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.menu = menu
        plan = IconAnimation.plan(for: .idle, reduceMotion: false)
        observeMotion()
        apply(.idle)
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
        plan = IconAnimation.plan(for: next, reduceMotion: reduceMotion)
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
        render()
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
                base = symbol(name)
            case .bars:
                base = drawBars()
            case .pulse:
                base = drawPulse()
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
        let moon = active.contains(.moon) ? symbol("moon.fill") : nil
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
        image.isTemplate = true
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

    private func canvas(_ handler: @escaping (NSRect) -> Void) -> NSImage {
        let size = NSSize(width: StatusIcon.side, height: StatusIcon.side)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            handler(rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "garime whisper"
        return image
    }

    private func drawBars() -> NSImage {
        let heights = IconAnimation.barHeights(
            level: level,
            peak: peak,
            count: Config.meterBarCount
        )
        return canvas { rect in
            let count = CGFloat(heights.count)
            let barWidth: CGFloat = 2
            let gap: CGFloat = 1.6
            let total = count * barWidth + (count - 1) * gap
            var x = rect.midX - total / 2
            let maxHeight = rect.height - 3
            for value in heights {
                let height = max(2, maxHeight * CGFloat(value))
                let bar = NSRect(
                    x: x,
                    y: rect.midY - height / 2,
                    width: barWidth,
                    height: height
                )
                NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
                x += barWidth + gap
            }
        }
    }

    private func drawPulse() -> NSImage {
        let span = max(1, plan.frameCount - 1)
        let progress = CGFloat(min(frameIndex, span)) / CGFloat(span)
        return canvas { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let dot = NSRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)
            NSBezierPath(ovalIn: dot).fill()

            let radius = 3.5 + progress * 4.5
            let ring = NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            ring.lineWidth = 1.4
            NSColor.black.withAlphaComponent(max(0, 0.85 * (1 - progress))).setStroke()
            ring.stroke()
        }
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
