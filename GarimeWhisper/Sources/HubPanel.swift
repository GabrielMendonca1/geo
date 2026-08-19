import AppKit

struct HubRow: Equatable {
    let symbol: String
    let title: String
    let trailing: String?
}

struct HubSection: Equatable {
    let pre: String
    let strong: String
    let post: String
    let rows: [HubRow]
    let empty: String?
}

enum HubModel {
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let head = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return head + "…"
    }

    static func dateHeader(_ date: Date, locale: Locale) -> (String, String) {
        let weekday = DateFormatter()
        weekday.locale = locale
        weekday.dateFormat = "EEEE"
        let rest = DateFormatter()
        rest.locale = locale
        rest.dateFormat = "d 'de' MMMM 'de' yyyy"
        let name = weekday.string(from: date)
        return (name.prefix(1).uppercased() + name.dropFirst(), rest.string(from: date))
    }

    static func tasksSection(_ tasks: [VaultTask], limit: Int, titleLimit: Int) -> HubSection {
        var rows = tasks.prefix(limit).map { task in
            HubRow(
                symbol: "circle",
                title: truncate(task.title, limit: titleLimit),
                trailing: VaultTasks.dueLabel(task.due)
            )
        }
        let hidden = tasks.count - rows.count
        if hidden > 0 {
            rows.append(HubRow(symbol: "ellipsis", title: "e mais \(hidden)", trailing: nil))
        }
        let strong: String
        switch tasks.count {
        case 0: strong = "nenhuma tarefa"
        case 1: strong = "1 tarefa"
        default: strong = "\(tasks.count) tarefas"
        }
        return HubSection(
            pre: "Você tem ",
            strong: strong,
            post: tasks.count == 1 ? " aberta" : " abertas",
            rows: rows,
            empty: tasks.isEmpty ? "tudo limpo por aqui" : nil
        )
    }

    static func projectsSection(_ projects: [ProjectStatus], limit: Int, titleLimit: Int) -> HubSection {
        let ordered = projects.sorted { $0.todos.count > $1.todos.count }
        var rows = ordered.prefix(limit).map { project in
            HubRow(
                symbol: "circle.dotted",
                title: truncate(project.name, limit: titleLimit),
                trailing: "\(project.todos.count)"
            )
        }
        let hidden = ordered.count - rows.count
        if hidden > 0 {
            rows.append(HubRow(symbol: "ellipsis", title: "e mais \(hidden)", trailing: nil))
        }
        let strong: String
        switch ordered.count {
        case 0: strong = "nenhum projeto"
        case 1: strong = "1 projeto"
        default: strong = "\(ordered.count) projetos"
        }
        return HubSection(
            pre: "Você tem ",
            strong: strong,
            post: ordered.count == 1 ? " com pendências" : " com pendências",
            rows: rows,
            empty: ordered.isEmpty ? "nenhum STATUS.md com todos" : nil
        )
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

enum HubInk {
    static let title = NSColor(calibratedWhite: 0.96, alpha: 1)
    static let strong = NSColor(calibratedWhite: 0.95, alpha: 1)
    static let muted = NSColor(calibratedWhite: 1, alpha: 0.48)
    static let body = NSColor(calibratedWhite: 1, alpha: 0.72)
    static let glyph = NSColor(calibratedWhite: 1, alpha: 0.42)
    static let rail = NSColor(calibratedWhite: 1, alpha: 0.16)
    static let faint = NSColor(calibratedWhite: 1, alpha: 0.28)
}

final class HubCardView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Config.panelCornerRadius
        let card = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0.055, alpha: 0.985).setFill()
        card.fill()

        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        let sheen = NSGradient(colors: [
            NSColor(calibratedWhite: 1, alpha: 0.05),
            NSColor(calibratedWhite: 1, alpha: 0),
        ])
        sheen?.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.6), angle: 270)
        NSGraphicsContext.current?.compositingOperation = .plusLighter
        NSColor(patternImage: HubCardView.noiseTile).withAlphaComponent(0.04).setFill()
        bounds.fill()
        NSGraphicsContext.restoreGraphicsState()

        let hairline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: radius,
            yRadius: radius
        )
        hairline.lineWidth = 1
        NSColor(calibratedWhite: 1, alpha: 0.09).setStroke()
        hairline.stroke()
    }

    static let noiseTile: NSImage = makeNoiseTile()

    private static func makeNoiseTile() -> NSImage {
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            var y: CGFloat = 0
            while y < rect.height {
                var x: CGFloat = 0
                while x < rect.width {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let value = CGFloat((seed >> 33) % 1000) / 1000
                    NSColor(calibratedWhite: value, alpha: 0.5).setFill()
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                    x += 1
                }
                y += 1
            }
            return true
        }
    }
}

enum HubPanelView {
    static func build(
        header: (String, String),
        sections: [HubSection],
        notice: String?,
        footer: String,
        actionTarget: AnyObject,
        actionSelector: Selector
    ) -> NSView {
        let width = Config.panelWidth
        let inset = Config.panelInset
        let rowHeight = Config.panelRowHeight
        var height = Config.panelTopPad + 22 + Config.panelHeaderGap
        if notice != nil { height += 24 }
        for section in sections {
            height += 20 + 8
            height += CGFloat(max(section.rows.count, section.empty == nil ? 0 : 1)) * rowHeight
            height += Config.panelSectionGap
        }
        height += 18 + Config.panelBottomPad

        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = Config.panelTopPad

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: header.0 + " ", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: HubInk.title,
        ]))
        title.append(NSAttributedString(string: header.1, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: HubInk.title,
        ]))
        let titleLabel = NSTextField(labelWithAttributedString: title)
        titleLabel.frame = NSRect(x: inset, y: y, width: width - inset * 2 - 40, height: 22)
        container.addSubview(titleLabel)

        let more = NSButton(frame: NSRect(x: width - inset - 26, y: y - 2, width: 26, height: 26))
        more.bezelStyle = .circular
        more.isBordered = false
        more.wantsLayer = true
        more.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
        more.layer?.cornerRadius = 13
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Ações")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        more.contentTintColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        more.imagePosition = .imageOnly
        more.target = actionTarget
        more.action = actionSelector
        container.addSubview(more)
        y += 22 + Config.panelHeaderGap

        if let notice {
            let label = NSTextField(labelWithString: notice)
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = .systemOrange
            label.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 16)
            container.addSubview(label)
            y += 24
        }

        for section in sections {
            let head = NSMutableAttributedString()
            head.append(NSAttributedString(string: section.pre, attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: HubInk.muted,
            ]))
            head.append(NSAttributedString(string: section.strong, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: HubInk.strong,
            ]))
            head.append(NSAttributedString(string: section.post, attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: HubInk.muted,
            ]))
            let headLabel = NSTextField(labelWithAttributedString: head)
            headLabel.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 20)
            container.addSubview(headLabel)
            y += 20 + 8

            if section.rows.isEmpty, let empty = section.empty {
                let label = NSTextField(labelWithString: empty)
                label.font = NSFont.systemFont(ofSize: 13)
                label.textColor = HubInk.faint
                label.frame = NSRect(x: Config.panelTextX, y: y + 8, width: width - Config.panelTextX - inset, height: 18)
                container.addSubview(label)
                y += rowHeight
            }

            for row in section.rows {
                container.addSubview(dash(y: y, rowHeight: rowHeight, x: inset))
                let glyph = NSImageView(frame: NSRect(
                    x: Config.panelGlyphX,
                    y: y + (rowHeight - 18) / 2,
                    width: 18,
                    height: 18
                ))
                glyph.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 14, weight: .light))
                glyph.contentTintColor = HubInk.glyph
                container.addSubview(glyph)

                let text = NSMutableAttributedString()
                text.append(NSAttributedString(string: row.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: HubInk.body,
                ]))
                if let trailing = row.trailing {
                    text.append(NSAttributedString(string: "  " + trailing, attributes: [
                        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                        .foregroundColor: HubInk.strong,
                    ]))
                }
                let label = NSTextField(labelWithAttributedString: text)
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.frame = NSRect(
                    x: Config.panelTextX,
                    y: y + (rowHeight - 18) / 2,
                    width: width - Config.panelTextX - inset + 12,
                    height: 18
                )
                container.addSubview(label)
                y += rowHeight
            }
            y += Config.panelSectionGap
        }

        let stamp = NSTextField(labelWithString: footer)
        stamp.font = NSFont.systemFont(ofSize: 11)
        stamp.textColor = HubInk.faint
        stamp.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 16)
        container.addSubview(stamp)

        return container
    }

    private static func dash(y: CGFloat, rowHeight: CGFloat, x: CGFloat) -> NSView {
        let height = rowHeight - 14
        let mark = NSView(frame: NSRect(x: x, y: y + 7, width: 2, height: height))
        mark.wantsLayer = true
        mark.layer?.backgroundColor = HubInk.rail.cgColor
        mark.layer?.cornerRadius = 1
        return mark
    }
}

final class HubPanel {
    private var panel: NSPanel?
    private var monitor: Any?

    var isOpen: Bool { panel?.isVisible ?? false }

    func show(content: NSView, below button: NSStatusBarButton?) {
        close()
        let size = content.frame.size
        let host = HubCardView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.addSubview(content)

        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrameOrigin(origin(for: size, below: button))
        window.orderFrontRegardless()
        panel = window

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.close()
        }
    }

    func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func origin(for size: NSSize, below button: NSStatusBarButton?) -> NSPoint {
        guard let button, let window = button.window else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12)
        }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - size.height - Config.panelGap
        return NSPoint(x: x, y: max(y, visible.minY + 8))
    }
}
