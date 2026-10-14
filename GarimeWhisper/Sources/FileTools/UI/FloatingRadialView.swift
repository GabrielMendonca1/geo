import AppKit
import QuartzCore

enum FloatingRadialHit: Equatable {
    case sector(Int)
    case center
    case outside
}

enum FloatingRadialOptions {
    static let packageFormats: Set<String> = ["tar", "zip", "gzip", "rar"]

    static let convertOrder = [
        "mp4",
        "mov",
        "mkv",
        "gif",
        "mp3",
        "m4a",
        "wav",
        "flac",
        "png",
        "jpg",
        "webp",
        "heic",
        "tiff",
        "pdf",
        "txt",
        "docx",
    ]

    static let toolOrder = [
        "compress",
        "removeMetadata",
        "mute",
        "trim",
        "crop",
        "speed",
        "snapshot",
        "split",
        "normalize",
        "channels",
        "scanQRCode",
        "extract",
    ]

    static func convert(
        category: FilesCategory,
        sourceExtension: String,
        capability: FilesCapability = .unknown
    ) -> [FilesOption] {
        let source = FilesCatalog.normalize(sourceExtension)
        let flat = FilesCatalog
            .convertGroups(category: category, sourceExtension: sourceExtension, capability: capability)
            .flatMap(\.options)
            .filter { option in
                guard option.kind == "convert", let format = option.format else { return false }
                return format != source
            }
        return normalizeConvert(flat)
    }

    static func normalizeConvert(_ options: [FilesOption]) -> [FilesOption] {
        var seen = Set<String>()
        let unique = options.filter { option in
            guard !packageFormats.contains(option.format ?? "") else { return false }
            return seen.insert(option.id).inserted
        }
        return unique.sorted { lhs, rhs in
            let left = convertRank(lhs)
            let right = convertRank(rhs)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    static func normalizeTools(_ options: [FilesOption]) -> [FilesOption] {
        var seen = Set<String>()
        let unique = options.filter { seen.insert($0.id).inserted }
        return unique.sorted { lhs, rhs in
            let left = rank(lhs.kind)
            let right = rank(rhs.kind)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    static func normalize(_ options: [FilesOption], mode: FilesMode) -> [FilesOption] {
        mode == .tools ? normalizeTools(options) : normalizeConvert(options)
    }

    private static func convertRank(_ option: FilesOption) -> Int {
        guard option.kind == "convert",
              let format = option.format,
              let index = convertOrder.firstIndex(of: format) else { return convertOrder.count }
        return index
    }

    static func tools(
        category: FilesCategory,
        capability: FilesCapability = .unknown
    ) -> [FilesOption] {
        let flat = FilesCatalog
            .toolGroups(category: category, capability: capability)
            .flatMap(\.options)
        return normalizeTools(flat)
    }

    private static func rank(_ kind: String) -> Int {
        toolOrder.firstIndex(of: kind) ?? toolOrder.count
    }
}

@objc(FloatingRadialView)
final class FloatingRadialView: NSView, FilesWheelSurface {
    static var playSectorChangedFeedback: (() -> Void)?
    static var playSelectionFeedback: (() -> Void)?

    static func installFeedback(sectorChanged: (() -> Void)?, selection: (() -> Void)?) {
        playSectorChangedFeedback = sectorChanged
        playSelectionFeedback = selection
    }

    static let minDiameter: CGFloat = 320
    static let maxDiameter: CGFloat = 380
    static let padding: CGFloat = 28

    static func clampDiameter(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return minDiameter }
        return min(max(value, minDiameter), maxDiameter)
    }

    static func preferredDiameter(screenFrame: NSRect) -> CGFloat {
        clampDiameter(min(screenFrame.width, screenFrame.height) * 0.42)
    }

    static func preferredDiameter(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return minDiameter }
        return preferredDiameter(screenFrame: screen.visibleFrame)
    }

    static func viewSize(diameter: CGFloat) -> NSSize {
        let side = clampDiameter(diameter) + padding
        return NSSize(width: side, height: side)
    }

    private static let holeRatio: CGFloat = 0.170
    private static let innerRatio: CGFloat = 0.215
    private static let outerRatio: CGFloat = 0.490

    var holeRadius: CGFloat { diameter * Self.holeRatio }
    var sectorInnerRadius: CGFloat { diameter * Self.innerRatio }
    var sectorOuterRadius: CGFloat { diameter * Self.outerRatio }

    private var sectorCorner: CGFloat { max(diameter * 0.018, 4) }
    private var fontScale: CGFloat { diameter / 360 }

    private let cream = NSColor(srgbRed: 0.965, green: 0.957, blue: 0.941, alpha: 0.62)
    private let creamEdge = NSColor(white: 1, alpha: 0.32)
    private let hot = NSColor(srgbRed: 0xF4 / 255.0, green: 0x5D / 255.0, blue: 0x22 / 255.0, alpha: 0.96)
    private let ink = NSColor(white: 0.11, alpha: 1)
    private let inkFaint = NSColor(white: 0.42, alpha: 1)

    var options: [FilesOption] = [] {
        didSet {
            if let index = selectedIndex, !options.indices.contains(index) {
                selectedIndex = nil
            }
            refresh()
        }
    }

    var diameter: CGFloat = FloatingRadialView.minDiameter {
        didSet {
            let clamped = Self.clampDiameter(diameter)
            if clamped != diameter {
                diameter = clamped
                return
            }
            refresh()
        }
    }

    var fileName: String = "" { didSet { canvas.needsDisplay = true } }
    var fileIcon: NSImage? { didSet { canvas.needsDisplay = true } }

    private(set) var files: [URL] = []

    var sourceExtension: String { files.first?.pathExtension.lowercased() ?? "" }

    @objc func setFiles(_ urls: [URL]) {
        files = urls
        guard let first = urls.first else {
            fileName = ""
            fileIcon = nil
            return
        }
        fileName = urls.count > 1 ? "\(urls.count) arquivos" : first.lastPathComponent
        fileIcon = NSWorkspace.shared.icon(forFile: first.path)
    }

    private(set) var selectedIndex: Int? {
        didSet { canvas.needsDisplay = true }
    }

    var onSelectionChange: ((FilesOption?) -> Void)?
    var onCommit: ((FilesOption) -> Void)?

    var selectedOption: FilesOption? {
        guard let index = selectedIndex, options.indices.contains(index) else { return nil }
        return options[index]
    }

    private let backdrop = NSVisualEffectView()
    private lazy var canvas = FloatingRadialCanvas(owner: self)

    required override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)

        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)

        diameter = Self.clampDiameter(min(frameRect.width, frameRect.height) - Self.padding)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let fitted = Self.clampDiameter(min(bounds.width, bounds.height) - Self.padding)
        if fitted != diameter { diameter = fitted }
        backdrop.frame = bounds
        canvas.frame = bounds
        applyBackdropMask()
    }

    var preferredSide: CGFloat { Self.viewSize(diameter: diameter).width }

    func prepare(forScreen screen: NSRect) {
        let wanted = Self.preferredDiameter(screenFrame: screen)
        if wanted != diameter { diameter = wanted }
    }

    func apply(groups: [FilesGroup], mode: FilesMode, headline: String, footnote: String) {
        _ = headline
        _ = footnote
        let keep = selectedOption?.id
        options = FloatingRadialOptions.normalize(groups.flatMap(\.options), mode: mode)
        selectedIndex = keep.flatMap { id in options.firstIndex { $0.id == id } }
    }

    func reset() {
        selectedIndex = nil
    }

    private func refresh() {
        canvas.needsDisplay = true
        applyBackdropMask()
    }

    func centerCoordinates() -> NSPoint {
        NSPoint(x: bounds.midX, y: bounds.midY)
    }

    func centerCoordinatesInWindow() -> NSPoint {
        convert(centerCoordinates(), to: nil)
    }

    func centerCoordinatesOnScreen() -> NSPoint? {
        guard let window else { return nil }
        let inWindow = centerCoordinatesInWindow()
        return window.convertPoint(toScreen: inWindow)
    }

    func sectorSpan(_ index: Int) -> (start: CGFloat, end: CGFloat)? {
        guard options.indices.contains(index) else { return nil }
        let step = 360 / CGFloat(options.count)
        let end = 90 + step / 2 - CGFloat(index) * step
        return (end - step, end)
    }

    func sectorMidAngle(_ index: Int) -> CGFloat? {
        guard let span = sectorSpan(index) else { return nil }
        var mid = (span.start + span.end) / 2
        while mid < 0 { mid += 360 }
        while mid >= 360 { mid -= 360 }
        return mid
    }

    func sectorMidpoint(_ index: Int) -> NSPoint? {
        guard let angle = sectorMidAngle(index) else { return nil }
        let radius = (sectorInnerRadius + sectorOuterRadius) / 2
        return point(angle: angle, radius: radius)
    }

    private func point(angle: CGFloat, radius: CGFloat) -> NSPoint {
        let center = centerCoordinates()
        let radians = angle * .pi / 180
        return NSPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    private func angle(of point: NSPoint) -> CGFloat {
        let center = centerCoordinates()
        var degrees = atan2(point.y - center.y, point.x - center.x) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    private func distance(of point: NSPoint) -> CGFloat {
        let center = centerCoordinates()
        return hypot(point.x - center.x, point.y - center.y)
    }

    private func sectorIndex(angle: CGFloat) -> Int? {
        guard !options.isEmpty else { return nil }
        let step = 360 / CGFloat(options.count)
        var delta = 90 + step / 2 - angle
        while delta < 0 { delta += 360 }
        while delta >= 360 { delta -= 360 }
        let index = Int(delta / step)
        return min(max(index, 0), options.count - 1)
    }

    func hit(at point: NSPoint) -> FloatingRadialHit {
        let radius = distance(of: point)
        if radius <= holeRadius { return .center }
        guard radius >= sectorInnerRadius, radius <= sectorOuterRadius else { return .outside }
        guard let index = sectorIndex(angle: angle(of: point)) else { return .outside }
        return .sector(index)
    }

    func hit(screenPoint: NSPoint) -> FloatingRadialHit {
        guard let local = convertFromScreen(screenPoint) else { return .outside }
        return hit(at: local)
    }

    @discardableResult
    func track(at point: NSPoint) -> Bool {
        if case .sector = trackHit(at: point) { return true }
        return false
    }

    @discardableResult
    func track(screenPoint: NSPoint) -> Bool {
        if case .sector = trackHit(screenPoint: screenPoint) { return true }
        return false
    }

    @discardableResult
    func trackHit(at point: NSPoint) -> FloatingRadialHit {
        let result = hit(at: point)
        switch result {
        case let .sector(index):
            apply(index)
        case .center, .outside:
            apply(nil)
        }
        return result
    }

    @discardableResult
    func trackHit(screenPoint: NSPoint) -> FloatingRadialHit {
        guard let local = convertFromScreen(screenPoint) else {
            apply(nil)
            return .outside
        }
        return trackHit(at: local)
    }

    func clearSelection() { apply(nil) }

    func commit() {
        guard let option = selectedOption else { return }
        Self.playSelectionFeedback?()
        onCommit?(option)
    }

    private func apply(_ next: Int?) {
        guard next != selectedIndex else { return }
        selectedIndex = next
        if next != nil { Self.playSectorChangedFeedback?() }
        onSelectionChange?(selectedOption)
    }

    private func convertFromScreen(_ point: NSPoint) -> NSPoint? {
        guard let window else { return nil }
        let inWindow = window.convertPoint(fromScreen: point)
        return convert(inWindow, from: nil)
    }

    private func maskPath() -> NSBezierPath {
        let path = NSBezierPath()
        for index in options.indices {
            guard let span = sectorSpan(index) else { continue }
            path.append(sectorPath(start: span.start, end: span.end))
        }
        let hole = NSRect(
            x: centerCoordinates().x - holeRadius,
            y: centerCoordinates().y - holeRadius,
            width: holeRadius * 2,
            height: holeRadius * 2
        )
        path.append(NSBezierPath(ovalIn: hole))
        return path
    }

    private func applyBackdropMask() {
        guard backdrop.layer != nil else { return }
        let shape = CAShapeLayer()
        shape.frame = backdrop.bounds
        shape.path = cgPath(from: maskPath())
        shape.fillRule = .nonZero
        backdrop.layer?.mask = options.isEmpty ? nil : shape
        backdrop.isHidden = options.isEmpty
    }

    private func cgPath(from path: NSBezierPath) -> CGPath {
        let flat = path.copy() as! NSBezierPath
        let result = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0 ..< flat.elementCount {
            switch flat.element(at: index, associatedPoints: &points) {
            case .moveTo:
                result.move(to: points[0])
            case .lineTo:
                result.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                result.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                result.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                result.closeSubpath()
            @unknown default:
                continue
            }
        }
        return result
    }

    private func sectorPath(start: CGFloat, end: CGFloat) -> NSBezierPath {
        let corner = sectorCorner
        let inner = sectorInnerRadius + corner
        let outer = max(sectorOuterRadius - corner, inner + 0.5)
        let padOuter = (corner / max(outer, 1)) * 180 / .pi + 1.1
        let padInner = (corner / max(inner, 1)) * 180 / .pi + 1.1
        let center = centerCoordinates()
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: outer, startAngle: start + padOuter, endAngle: end - padOuter, clockwise: false)
        path.appendArc(withCenter: center, radius: inner, startAngle: end - padInner, endAngle: start + padInner, clockwise: true)
        path.close()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.lineWidth = corner * 2
        return path
    }

    fileprivate func render(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        for (index, option) in options.enumerated() {
            guard let span = sectorSpan(index) else { continue }
            let path = sectorPath(start: span.start, end: span.end)
            let active = selectedIndex == index
            let fill = active ? hot : cream
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            context?.setAlpha(fill.alphaComponent)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
            let solid = fill.withAlphaComponent(1)
            solid.setFill()
            solid.setStroke()
            path.fill()
            path.stroke()
            if !active {
                creamEdge.setStroke()
                path.lineWidth = max(sectorCorner * 2 - 1.5, 1)
                path.stroke()
                path.lineWidth = sectorCorner * 2
            }
            context?.endTransparencyLayer()
            context?.restoreGState()
            drawSectorLabel(option: option, index: index, active: active)
        }

        drawCenter()
    }

    private func drawSectorLabel(option: FilesOption, index: Int, active: Bool) {
        guard let point = sectorMidpoint(index) else { return }
        let isFormat = option.kind == "convert"
        let text = isFormat ? (option.format?.uppercased() ?? option.title.uppercased()) : option.title
        let size = (isFormat ? 17 : 12) * fontScale
        let width = min(sectorOuterRadius - sectorInnerRadius, 118 * fontScale) + 22 * fontScale
        draw(
            text: text,
            at: point,
            size: size,
            weight: isFormat ? .bold : .semibold,
            color: active ? .white : ink,
            width: width
        )
    }

    private func drawCenter() {
        let center = centerCoordinates()
        let hole = NSBezierPath(ovalIn: NSRect(
            x: center.x - holeRadius,
            y: center.y - holeRadius,
            width: holeRadius * 2,
            height: holeRadius * 2
        ))
        NSColor(white: 1, alpha: 0.30).setFill()
        hole.fill()

        let iconSide = holeRadius * 0.86
        if let icon = fileIcon {
            let rect = NSRect(
                x: center.x - iconSide / 2,
                y: center.y - iconSide / 2 + holeRadius * 0.24,
                width: iconSide,
                height: iconSide
            )
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        let pill = selectedOption.map { option -> String in
            option.kind == "convert" ? (option.format?.uppercased() ?? option.title) : option.title
        } ?? shortName(fileName)
        guard !pill.isEmpty else { return }
        drawPill(text: pill, centerY: center.y - holeRadius * 0.44)
    }

    private func shortName(_ name: String) -> String {
        guard name.count > 16 else { return name }
        return String(name.prefix(15)) + "…"
    }

    private func drawPill(text: String, centerY: CGFloat) {
        let center = centerCoordinates()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11 * fontScale, weight: .semibold),
            .foregroundColor: ink,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let maxWidth = holeRadius * 1.8
        let width = min(size.width, maxWidth)
        let box = NSRect(
            x: center.x - width / 2 - 9 * fontScale,
            y: centerY - size.height / 2 - 3 * fontScale,
            width: width + 18 * fontScale,
            height: size.height + 6 * fontScale
        )
        let path = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
        NSColor(white: 1, alpha: 0.97).setFill()
        path.fill()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        var textAttributes = attributes
        textAttributes[.paragraphStyle] = style
        (text as NSString).draw(
            in: NSRect(x: box.minX, y: box.minY + 3 * fontScale, width: box.width, height: size.height),
            withAttributes: textAttributes
        )
    }

    private func draw(
        text: String,
        at point: NSPoint,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        width: CGFloat
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        var fitted = size
        while fitted > size * 0.72 {
            let probe = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fitted, weight: weight)])
            if probe.width <= width { break }
            fitted -= 0.25
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fitted, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let rect = NSRect(x: point.x - width / 2, y: point.y - size * 0.7, width: width, height: size * 1.5)
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    func snapshotImage(includingBackdrop: Bool = true) -> NSBitmapImageRep? {
        layoutSubtreeIfNeeded()
        let hidden = backdrop.isHidden
        if !includingBackdrop { backdrop.isHidden = true }
        defer { backdrop.isHidden = hidden }
        canvas.display()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        return rep
    }
}

private final class FloatingRadialCanvas: NSView {
    private weak var owner: FloatingRadialView?

    init(owner: FloatingRadialView) {
        self.owner = owner
        super.init(frame: owner.bounds)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        owner?.render(dirtyRect)
    }
}
