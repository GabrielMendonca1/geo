import AppKit

final class RadialMenuView: NSView {
    struct Selection: Equatable {
        var group: Int
        var option: Int?
    }

    enum Hit: Equatable {
        case group(Int)
        case option(Int)
        case hub
        case outside
    }

    static let diameter: CGFloat = 440
    static var playSectorChangedFeedback: (() -> Void)?
    static var playSelectionFeedback: (() -> Void)?

    static func side(scale: CGFloat) -> CGFloat { diameter * scale + 28 }

    var scale: CGFloat = 1 { didSet { needsDisplay = true } }

    private var hubRadius: CGFloat { 62 * scale }
    private var innerIn: CGFloat { 66 * scale }
    private var innerOut: CGFloat { 116 * scale }
    private var outerIn: CGFloat { 122 * scale }
    private var outerOut: CGFloat { 196 * scale }

    private var font: CGFloat { max(scale, 0.85) }

    var groups: [TangerineGroup] = [] {
        didSet {
            if selection.group >= groups.count { selection = Selection(group: 0, option: nil) }
            needsDisplay = true
        }
    }

    var mode: TangerineMode = .convert { didSet { needsDisplay = true } }
    var dimmed = false { didSet { needsDisplay = true } }
    var headline: String = "" { didSet { needsDisplay = true } }
    var footnote: String = "" { didSet { needsDisplay = true } }
    var selection = Selection(group: 0, option: nil) { didSet { needsDisplay = true } }
    var onSelectionChange: ((TangerineOption?) -> Void)?
    var onCommit: ((TangerineOption) -> Void)?

    var currentOption: TangerineOption? {
        guard groups.indices.contains(selection.group) else { return nil }
        let options = groups[selection.group].options
        guard let index = selection.option, options.indices.contains(index) else { return nil }
        return options[index]
    }

    var currentGroup: TangerineGroup? {
        groups.indices.contains(selection.group) ? groups[selection.group] : nil
    }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    private func angle(of point: NSPoint) -> CGFloat {
        let dx = point.x - center.x
        let dy = point.y - center.y
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    private func distance(of point: NSPoint) -> CGFloat {
        hypot(point.x - center.x, point.y - center.y)
    }

    private func span(index: Int, count: Int) -> (CGFloat, CGFloat) {
        guard count > 0 else { return (0, 360) }
        let step = 360 / CGFloat(count)
        let end = 90 - CGFloat(index) * step
        let start = end - step
        return (start, end)
    }

    private func sectorIndex(angle: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let step = 360 / CGFloat(count)
        var delta = 90 - angle
        while delta < 0 { delta += 360 }
        while delta >= 360 { delta -= 360 }
        let index = Int(delta / step)
        return min(max(index, 0), count - 1)
    }

    func hit(at point: NSPoint) -> Hit {
        let radius = distance(of: point)
        if radius <= hubRadius { return .hub }
        let theta = angle(of: point)
        if radius >= innerIn, radius <= innerOut {
            if let index = sectorIndex(angle: theta, count: groups.count) { return .group(index) }
        }
        if radius >= outerIn, radius <= outerOut {
            let count = currentGroup?.options.count ?? 0
            if let index = sectorIndex(angle: theta, count: count) { return .option(index) }
        }
        return .outside
    }

    @discardableResult
    func track(at point: NSPoint) -> Hit {
        let result = hit(at: point)
        var next = selection
        switch result {
        case let .group(index):
            if next.group != index {
                next.group = index
                next.option = nil
            }
        case let .option(index):
            next.option = index
        case .hub, .outside:
            break
        }
        applySelection(next)
        return result
    }

    func moveGroup(_ delta: Int) {
        guard !groups.isEmpty else { return }
        var index = selection.group + delta
        if index < 0 { index = groups.count - 1 }
        if index >= groups.count { index = 0 }
        applySelection(Selection(group: index, option: nil))
    }

    func moveOption(_ delta: Int) {
        guard let options = currentGroup?.options, !options.isEmpty else { return }
        var index = (selection.option ?? -1) + delta
        if index < 0 { index = options.count - 1 }
        if index >= options.count { index = 0 }
        applySelection(Selection(group: selection.group, option: index))
    }

    func commit() {
        guard let option = currentOption else { return }
        Self.playSelectionFeedback?()
        onCommit?(option)
    }

    private func applySelection(_ next: Selection) {
        guard next != selection else { return }
        selection = next
        Self.playSectorChangedFeedback?()
        onSelectionChange?(currentOption)
    }

    override func mouseMoved(with event: NSEvent) {
        track(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let result = track(at: point)
        if case .option = result { commit() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    private func roundedSector(
        radiusIn: CGFloat,
        radiusOut: CGFloat,
        start: CGFloat,
        end: CGFloat,
        corner: CGFloat
    ) -> NSBezierPath {
        let rIn = radiusIn + corner
        let rOut = max(radiusOut - corner, rIn + 0.5)
        let padOuter = (corner / max(rOut, 1)) * 180 / .pi + 0.9
        let padInner = (corner / max(rIn, 1)) * 180 / .pi + 0.9
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: rOut, startAngle: start + padOuter, endAngle: end - padOuter, clockwise: false)
        path.appendArc(withCenter: center, radius: rIn, startAngle: end - padInner, endAngle: start + padInner, clockwise: true)
        path.close()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.lineWidth = corner * 2
        return path
    }

    private func paint(_ path: NSBezierPath, color: NSColor) {
        color.setFill()
        color.setStroke()
        path.fill()
        path.stroke()
    }

    private func draw(text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, width: CGFloat = 110) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let fitted = fittedSize(text: text, size: size, weight: weight, width: width)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fitted, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let rect = NSRect(x: point.x - width / 2, y: point.y - size * 0.75, width: width, height: size * 1.6)
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func fittedSize(text: String, size: CGFloat, weight: NSFont.Weight, width: CGFloat) -> CGFloat {
        var fitted = size
        let floorSize = size * 0.74
        while fitted > floorSize {
            let probe = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fitted, weight: weight)])
            if probe.width <= width { break }
            fitted -= 0.25
        }
        return fitted
    }

    func innerLabelOverflow() -> [String] {
        var overflowing: [String] = []
        for (index, group) in groups.enumerated() {
            let (start, end) = span(index: index, count: groups.count)
            let mid = ((start + end) / 2) * .pi / 180
            guard abs(cos(mid)) > 0.9 else { continue }
            let width = labelWidth(
                index: index,
                count: groups.count,
                radiusIn: innerIn,
                radiusOut: innerOut,
                arcWidth: 64 * font
            )
            let radius = labelRadius(
                index: index,
                count: groups.count,
                radiusIn: innerIn,
                radiusOut: innerOut,
                bias: 0.62
            )
            let size = fittedSize(text: group.title, size: 10 * font, weight: .semibold, width: width)
            let drawn = (group.title as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            ])
            let room = 2 * min(radius - innerIn, innerOut - radius)
            if drawn.width > room + 1 { overflowing.append(group.title) }
        }
        return overflowing
    }

    private func labelWidth(index: Int, count: Int, radiusIn: CGFloat, radiusOut: CGFloat, arcWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return arcWidth }
        let (start, end) = span(index: index, count: count)
        let mid = ((start + end) / 2) * .pi / 180
        let horizontal = abs(cos(mid))
        let radialRoom = (radiusOut - radiusIn) * 0.88
        return arcWidth + (radialRoom - arcWidth) * horizontal
    }

    private func labelRadius(index: Int, count: Int, radiusIn: CGFloat, radiusOut: CGFloat, bias: CGFloat) -> CGFloat {
        guard count > 0 else { return (radiusIn + radiusOut) / 2 }
        let (start, end) = span(index: index, count: count)
        let mid = ((start + end) / 2) * .pi / 180
        let horizontal = abs(cos(mid))
        let factor = bias + (0.5 - bias) * horizontal
        return radiusIn + (radiusOut - radiusIn) * factor
    }

    private func capsule(text: String, centerY: CGFloat, size: CGFloat, weight: NSFont.Weight) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: TangerineTheme.ink,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let box = NSRect(
            x: center.x - textSize.width / 2 - 10,
            y: centerY - textSize.height / 2 - 4,
            width: textSize.width + 20,
            height: textSize.height + 8
        )
        let path = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
        NSColor(white: 1, alpha: 0.96).setFill()
        path.fill()
        (text as NSString).draw(
            at: NSPoint(x: box.minX + 10, y: box.minY + 4),
            withAttributes: attributes
        )
    }

    private func midpoint(index: Int, count: Int, radius: CGFloat) -> NSPoint {
        let (start, end) = span(index: index, count: count)
        let mid = ((start + end) / 2) * .pi / 180
        return NSPoint(x: center.x + cos(mid) * radius, y: center.y + sin(mid) * radius)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let discRadius = outerOut + 8 * scale
        let disc = NSBezierPath(ovalIn: NSRect(
            x: center.x - discRadius,
            y: center.y - discRadius,
            width: discRadius * 2,
            height: discRadius * 2
        ))
        NSColor(white: 0.98, alpha: 0.90).setFill()
        disc.fill()
        NSColor(white: 0, alpha: 0.08).setStroke()
        disc.lineWidth = 1
        disc.stroke()

        let options = currentGroup?.options ?? []

        let arcLabelWidth: CGFloat = (options.count >= 5 ? 84 : options.count >= 4 ? 96 : 112) * font
        for (index, option) in options.enumerated() {
            let optionLabelWidth = labelWidth(
                index: index,
                count: options.count,
                radiusIn: outerIn,
                radiusOut: outerOut,
                arcWidth: arcLabelWidth
            )
            let (start, end) = span(index: index, count: options.count)
            let hot = selection.option == index
            let path = roundedSector(
                radiusIn: outerIn,
                radiusOut: outerOut,
                start: start,
                end: end,
                corner: TangerineTheme.sectorCorner
            )
            paint(path, color: hot ? TangerineTheme.sectorHot : TangerineTheme.sector)
            let point = midpoint(index: index, count: options.count, radius: (outerIn + outerOut) / 2)

            draw(
                text: option.title,
                at: NSPoint(x: point.x, y: point.y + (option.detail.isEmpty ? 0 : 7 * font)),
                size: (option.title.count > 12 ? 12 : 13) * font,
                weight: .semibold,
                color: hot ? .white : TangerineTheme.ink,
                width: optionLabelWidth
            )
            if !option.detail.isEmpty {
                draw(
                    text: option.detail,
                    at: NSPoint(x: point.x, y: point.y - 8 * font),
                    size: 9.5 * font,
                    weight: .regular,
                    color: hot ? NSColor(white: 1, alpha: 1) : TangerineTheme.inkFaint,
                    width: optionLabelWidth
                )
            }
        }

        if options.isEmpty {
            draw(
                text: "nada disponível",
                at: NSPoint(x: center.x, y: center.y + (outerIn + outerOut) / 2),
                size: 12 * font,
                weight: .medium,
                color: TangerineTheme.inkFaint,
                width: 160
            )
        }

        for (index, group) in groups.enumerated() {
            let (start, end) = span(index: index, count: groups.count)
            let hot = selection.group == index
            let path = roundedSector(
                radiusIn: innerIn,
                radiusOut: innerOut,
                start: start,
                end: end,
                corner: TangerineTheme.sectorCorner
            )
            let strong = hot && !dimmed && selection.option != nil
            paint(path, color: strong ? TangerineTheme.sectorHotDeep : (hot ? TangerineTheme.sector : TangerineTheme.sectorDim))

            let point = midpoint(
                index: index,
                count: groups.count,
                radius: labelRadius(
                    index: index,
                    count: groups.count,
                    radiusIn: innerIn,
                    radiusOut: innerOut,
                    bias: 0.62
                )
            )
            draw(
                text: group.title,
                at: point,
                size: 10 * font,
                weight: hot ? .semibold : .medium,
                color: hot && !dimmed && selection.option != nil ? .white : TangerineTheme.inkSoft,

                width: labelWidth(
                    index: index,
                    count: groups.count,
                    radiusIn: innerIn,
                    radiusOut: innerOut,
                    arcWidth: 64 * font
                )
            )
        }

        let hub = NSBezierPath(ovalIn: NSRect(
            x: center.x - hubRadius,
            y: center.y - hubRadius,
            width: hubRadius * 2,
            height: hubRadius * 2
        ))
        TangerineTheme.hub.setFill()
        hub.fill()
        TangerineTheme.accent.withAlphaComponent(currentOption == nil || dimmed ? 0.25 : 1).setStroke()
        hub.lineWidth = 2
        hub.stroke()

        let modeText = mode.title.uppercased()
        draw(
            text: modeText,
            at: NSPoint(x: center.x, y: center.y + 30 * font),
            size: 9 * font,
            weight: .bold,
            color: dimmed ? TangerineTheme.inkFaint : TangerineTheme.accent,
            width: 100 * font
        )
        if let option = currentOption {
            let titleSize: CGFloat = option.title.count > 11 ? 12.5 : 16
            draw(
                text: option.title,
                at: NSPoint(x: center.x, y: center.y + 6 * font),
                size: titleSize * font,
                weight: .bold,
                color: TangerineTheme.ink,
                width: hubRadius * 1.9
            )
            if !option.detail.isEmpty {
                draw(text: option.detail, at: NSPoint(x: center.x, y: center.y - 12 * font), size: 10 * font, weight: .regular, color: TangerineTheme.inkFaint, width: 100 * font)
            }
            if option.needsParams {
                draw(text: "pede ajustes", at: NSPoint(x: center.x, y: center.y - 28 * font), size: 9 * font, weight: .semibold, color: TangerineTheme.accent, width: 100 * font)
            }
        } else {
            draw(text: "escolha", at: NSPoint(x: center.x, y: center.y + 4 * font), size: 14 * font, weight: .semibold, color: TangerineTheme.inkFaint, width: 100 * font)
            draw(text: "no anel externo", at: NSPoint(x: center.x, y: center.y - 14 * font), size: 9.5 * font, weight: .regular, color: TangerineTheme.inkFaint, width: 100 * font)
        }
        if !headline.isEmpty {
            capsule(text: headline, centerY: center.y + outerOut + 16 * font, size: 11.5 * font, weight: .semibold)
        }
        if !footnote.isEmpty {
            capsule(text: footnote, centerY: center.y - outerOut - 16 * font, size: 10.5 * font, weight: .medium)
        }
    }
}
