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
