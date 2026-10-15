import AppKit

enum FilesTheme {
    static let accent = NSColor(srgbRed: 0xF4 / 255.0, green: 0x5D / 255.0, blue: 0x22 / 255.0, alpha: 1)
    static let accentSoft = accent.withAlphaComponent(0.14)
    static let panel = NSColor(srgbRed: 0.937, green: 0.937, blue: 0.929, alpha: 1)
    static let card = NSColor.white
    static let cardStroke = NSColor(white: 0, alpha: 0.07)
    static let sector = NSColor(white: 0.84, alpha: 1)
    static let sectorHot = accent
    static let sectorHotDeep = NSColor(srgbRed: 0xD8 / 255.0, green: 0x4C / 255.0, blue: 0x18 / 255.0, alpha: 1)
    static let sectorDim = NSColor(white: 0.90, alpha: 1)
    static let hub = NSColor.white
    static let ink = NSColor(white: 0.12, alpha: 1)
    static let inkSoft = NSColor(white: 0.38, alpha: 1)
    static let inkFaint = NSColor(white: 0.58, alpha: 1)
    static let danger = NSColor(srgbRed: 0.78, green: 0.15, blue: 0.12, alpha: 1)
    static let ok = NSColor(srgbRed: 0.13, green: 0.52, blue: 0.26, alpha: 1)

    static let cardRadius: CGFloat = 14
    static let sectorCorner: CGFloat = 6

    static func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = FilesTheme.ink
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }
}

final class FilesCard: NSView {
    override var isFlipped: Bool { true }

    var active = false { didSet { applySkin() } }
    var radius: CGFloat = FilesTheme.cardRadius { didSet { applySkin() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applySkin()
    }

    required init?(coder: NSCoder) { nil }

    private func applySkin() {
        wantsLayer = true
        layer?.backgroundColor = FilesTheme.card.cgColor
        layer?.cornerRadius = radius
        layer?.borderWidth = active ? 2 : 1
        layer?.borderColor = (active ? FilesTheme.accent : FilesTheme.cardStroke).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.06
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    var backgroundIsWhite: Bool {
        guard let color = layer?.backgroundColor,
              let converted = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return false }
        return converted.redComponent > 0.99 && converted.greenComponent > 0.99 && converted.blueComponent > 0.99
    }
}

final class FilesPill: NSView {
    var title: String { didSet { needsDisplay = true } }
    var action: () -> Void
    private var hot = false
    private var tracking: NSTrackingArea?
    var selected = false { didSet { needsDisplay = true } }
    var enabledAction = true { didSet { needsDisplay = true } }
    var accessory: String?

    override var isFlipped: Bool { true }

    init(frame: NSRect, title: String, handler: @escaping () -> Void) {
        self.title = title
        self.action = handler
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hot = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hot = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard enabledAction, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let fill: NSColor
        if !enabledAction {
            fill = NSColor(white: 0.92, alpha: 1)
        } else if selected {
            fill = FilesTheme.accent
        } else if hot {
            fill = FilesTheme.accentSoft
        } else {
            fill = NSColor.white
        }
        fill.setFill()
        path.fill()
        (selected ? FilesTheme.accent : FilesTheme.cardStroke).setStroke()
        path.lineWidth = 1
        path.stroke()

        let color: NSColor = !enabledAction
            ? FilesTheme.inkFaint
            : (selected ? .white : FilesTheme.ink)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: selected ? .semibold : .medium),
            .foregroundColor: color,
        ]
        let text = accessory.map { "\(title)  \($0)" } ?? title
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}
