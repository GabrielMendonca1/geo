import AppKit

enum HubAction: Equatable {
    case dictate
    case meeting
    case call
    case insomnia
    case notes
    case refresh
    case quit
}

struct HubActionSpec: Equatable {
    let action: HubAction
    let symbol: String
    let tooltip: String
    let on: Bool
}

enum HubDueTone: Equatable {
    case none
    case later
    case today
    case overdue
}

struct HubRow: Equatable {
    let id: String
    let title: String
    let trailing: String?
    let tone: HubDueTone
    let tip: String?
}

struct HubSection: Equatable {
    let pre: String
    let strong: String
    let post: String
    let rows: [HubRow]
    let empty: String?
}

enum HubModel {
    static func dateHeader(_ date: Date, locale: Locale) -> (String, String) {
        let weekday = DateFormatter()
        weekday.locale = locale
        weekday.dateFormat = "EEEE"
        let rest = DateFormatter()
        rest.locale = locale
        rest.dateFormat = "d 'de' MMMM"
        let name = weekday.string(from: date)
        return (name.prefix(1).uppercased() + name.dropFirst(), rest.string(from: date))
    }

    static func priorityLabel(_ priority: String) -> String? {
        switch VaultTasks.priorityRank(priority) {
        case 0: return "prioridade alta"
        case 1: return "prioridade média"
        case 2: return "prioridade baixa"
        default: return nil
        }
    }

    static func taskTip(_ task: VaultTask) -> String {
        var parts: [String] = [task.title]
        if let priority = priorityLabel(task.priority) { parts.append(priority) }
        if let due = VaultTasks.dueLabel(task.due) { parts.append("vence " + due) }
        switch task.reminders {
        case 0: break
        case 1: parts.append("1 lembrete")
        default: parts.append("\(task.reminders) lembretes")
        }
        return parts.joined(separator: " · ")
    }

    static func dueTone(_ due: Date?, now: Date, calendar: Calendar = .current) -> HubDueTone {
        guard let due else { return .none }
        if calendar.isDate(due, inSameDayAs: now) { return .today }
        return due < calendar.startOfDay(for: now) ? .overdue : .later
    }

    static func dueText(_ due: Date?, tone: HubDueTone) -> String? {
        switch tone {
        case .none: return nil
        case .today: return "hoje"
        case .later, .overdue: return VaultTasks.dueLabel(due)
        }
    }

    static func tasksSection(_ tasks: [VaultTask], limit: Int, now: Date = Date()) -> HubSection {
        var rows = tasks.prefix(limit).map { task in
            let tone = dueTone(task.due, now: now)
            return HubRow(
                id: "task:" + task.id,
                title: task.title,
                trailing: dueText(task.due, tone: tone),
                tone: tone,
                tip: taskTip(task)
            )
        }
        let hidden = tasks.count - rows.count
        if hidden > 0 {
            rows.append(HubRow(id: "task:more", title: "e mais \(hidden)", trailing: nil, tone: .none, tip: nil))
        }
        let strong: String
        switch tasks.count {
        case 0: strong = "Nenhuma tarefa"
        case 1: strong = "1 tarefa"
        default: strong = "\(tasks.count) tarefas"
        }
        let overdue = tasks.filter { dueTone($0.due, now: now) == .overdue }.count
        var post = tasks.count == 1 ? " aberta" : " abertas"
        if overdue > 0 { post += overdue == 1 ? " · 1 atrasada" : " · \(overdue) atrasadas" }
        return HubSection(
            pre: "",
            strong: strong,
            post: post,
            rows: rows,
            empty: tasks.isEmpty ? "Tudo limpo por aqui" : nil
        )
    }

    static func actionSpecs(dictating: Bool, meeting: Bool) -> [HubActionSpec] {
        [
            HubActionSpec(
                action: .dictate,
                symbol: dictating ? "mic.fill" : "mic",
                tooltip: dictating ? "Parar e transcrever (⌥Space)" : "Ditar (⌥Space)",
                on: dictating
            ),
            HubActionSpec(
                action: .meeting,
                symbol: meeting ? "stop.fill" : "record.circle",
                tooltip: meeting ? "Parar reunião" : "Gravar reunião",
                on: meeting
            ),
            HubActionSpec(action: .notes, symbol: "folder", tooltip: "Abrir o Vault", on: false),
            HubActionSpec(action: .refresh, symbol: "arrow.clockwise", tooltip: "Atualizar tarefas agora", on: false),
        ]
    }
}

enum HubInk {
    static func due(_ tone: HubDueTone) -> NSColor {
        switch tone {
        case .overdue: return .systemRed
        case .today: return .systemOrange
        case .later, .none: return .secondaryLabelColor
        }
    }

    static func glyph(_ tone: HubDueTone) -> NSColor {
        switch tone {
        case .overdue: return NSColor.systemRed.withAlphaComponent(0.8)
        case .today: return NSColor.systemOrange.withAlphaComponent(0.8)
        case .later, .none: return .tertiaryLabelColor
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ClosureButton: NSButton {
    private var handler: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var restingFill: CGColor?
    private var hoverFill: CGColor?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    convenience init(frame: NSRect, handler: @escaping () -> Void) {
        self.init(frame: frame)
        self.handler = handler
        target = self
        action = #selector(fire)
    }

    func trackHover(resting: NSColor, hover: NSColor) {
        wantsLayer = true
        restingFill = resting.cgColor
        hoverFill = hover.cgColor
        layer?.backgroundColor = restingFill
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard hoverFill != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = hoverFill ?? restingFill
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = restingFill
    }

    @objc private func fire() {
        handler?()
    }
}

struct HubContent {
    let headerStrong: String
    let headerRest: String
    let sections: [HubSection]
    let footer: String
    let actions: [HubActionSpec]
}

enum HubPanelView {
    static func build(
        content: HubContent,
        onAction: @escaping (HubAction) -> Void
    ) -> NSView {
        let width = Config.panelWidth
        let inset = Config.panelInset
        let rowHeight = Config.panelRowHeight

        var bodyHeight: CGFloat = 6
        for section in content.sections {
            bodyHeight += CGFloat(max(section.rows.count, section.empty == nil ? 0 : 1)) * rowHeight
        }
        bodyHeight += 6
        let visibleBody = min(bodyHeight, Config.panelMaxBodyHeight)
        let headerHeight: CGFloat = Config.panelTopPad + 20 + 4 + 16 + 12
        let footerHeight: CGFloat = Config.panelActionSize + 20
        let height = headerHeight + 1 + visibleBody + 1 + footerHeight

        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = Config.panelTopPad

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: content.headerStrong, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        title.append(NSAttributedString(string: "  " + content.headerRest, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        let titleLabel = NSTextField(labelWithAttributedString: title)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 20)
        container.addSubview(titleLabel)
        y += 24

        if let section = content.sections.first {
            let summary = NSTextField(labelWithString: section.strong + section.post)
            summary.font = NSFont.systemFont(ofSize: 12)
            summary.textColor = .secondaryLabelColor
            summary.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 16)
            container.addSubview(summary)
        }
        y = headerHeight

        container.addSubview(divider(y: y, width: width))
        y += 1

        let body = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: bodyHeight))
        var rowY: CGFloat = 6
        for section in content.sections {
            if section.rows.isEmpty, let empty = section.empty {
                let label = NSTextField(labelWithString: empty)
                label.font = NSFont.systemFont(ofSize: 13)
                label.textColor = .tertiaryLabelColor
                label.frame = NSRect(x: inset, y: rowY + (rowHeight - 17) / 2, width: width - inset * 2, height: 17)
                body.addSubview(label)
                rowY += rowHeight
            }
            for row in section.rows {
                body.addSubview(rowView(row, y: rowY, width: width))
                rowY += rowHeight
            }
        }

        let scroller = NSScrollView(frame: NSRect(x: 0, y: y, width: width, height: visibleBody))
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = bodyHeight > visibleBody
        scroller.scrollerStyle = .overlay
        scroller.autohidesScrollers = true
        scroller.horizontalScrollElasticity = .none
        scroller.verticalScrollElasticity = bodyHeight > visibleBody ? .allowed : .none
        scroller.automaticallyAdjustsContentInsets = false
        scroller.documentView = body
        container.addSubview(scroller)
        y += visibleBody

        container.addSubview(divider(y: y, width: width))
        y += 1

        let barY = y + (footerHeight - Config.panelActionSize) / 2
        var x = inset - 6
        for spec in content.actions {
            container.addSubview(actionButton(spec, frame: NSRect(
                x: x,
                y: barY,
                width: Config.panelActionSize,
                height: Config.panelActionSize
            ), onAction: onAction))
            x += Config.panelActionSize + 4
        }

        let stamp = NSTextField(labelWithString: content.footer)
        stamp.font = NSFont.systemFont(ofSize: 11)
        stamp.textColor = .secondaryLabelColor
        stamp.alignment = .right
        stamp.lineBreakMode = .byTruncatingHead
        stamp.frame = NSRect(x: x + 8, y: barY + (Config.panelActionSize - 14) / 2, width: width - inset - x - 8, height: 14)
        container.addSubview(stamp)

        return container
    }

    private static func divider(y: CGFloat, width: CGFloat) -> NSView {
        let line = NSBox(frame: NSRect(x: 0, y: y, width: width, height: 1))
        line.boxType = .separator
        return line
    }

    private static func rowView(_ row: HubRow, y: CGFloat, width: CGFloat) -> NSView {
        let inset = Config.panelInset
        let rowHeight = Config.panelRowHeight
        let holder = FlippedView(frame: NSRect(x: 0, y: y, width: width, height: rowHeight))
        holder.toolTip = row.tip

        let more = row.id.hasSuffix(":more")
        let glyph = NSImageView(frame: NSRect(x: inset, y: (rowHeight - 14) / 2, width: 14, height: 14))
        glyph.image = NSImage(systemSymbolName: more ? "ellipsis" : "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        glyph.contentTintColor = HubInk.glyph(row.tone)
        holder.addSubview(glyph)

        let dueWidth: CGFloat = row.trailing == nil ? 0 : 44
        if let trailing = row.trailing {
            let due = NSTextField(labelWithString: trailing)
            due.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: row.tone == .later ? .regular : .medium)
            due.textColor = HubInk.due(row.tone)
            due.alignment = .right
            due.frame = NSRect(x: width - inset - dueWidth, y: (rowHeight - 15) / 2, width: dueWidth, height: 15)
            holder.addSubview(due)
        }

        let textX = inset + 24
        let label = NSTextField(labelWithString: row.title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = more ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.frame = NSRect(
            x: textX,
            y: (rowHeight - 17) / 2,
            width: width - textX - inset - dueWidth - (dueWidth > 0 ? 8 : 0),
            height: 17
        )
        holder.addSubview(label)
        return holder
    }

    private static func actionButton(
        _ spec: HubActionSpec,
        frame: NSRect,
        onAction: @escaping (HubAction) -> Void
    ) -> NSButton {
        let button = ClosureButton(frame: frame, handler: { onAction(spec.action) })
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.trackHover(
            resting: spec.on ? NSColor.systemRed.withAlphaComponent(0.9) : .clear,
            hover: spec.on ? NSColor.systemRed : NSColor.labelColor.withAlphaComponent(0.1)
        )
        button.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.tooltip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        button.contentTintColor = spec.on ? .white : .secondaryLabelColor
        button.imagePosition = .imageOnly
        button.toolTip = spec.tooltip
        button.setAccessibilityLabel(spec.tooltip)
        return button
    }
}

final class HubPanel {
    private let popover = NSPopover()
    private let host = NSViewController()

    var isOpen: Bool { popover.isShown }

    init() {
        host.view = FlippedView(frame: NSRect(x: 0, y: 0, width: Config.panelWidth, height: 10))
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
    }

    static func availableHeight(anchorBottom: CGFloat, screenBottom: CGFloat) -> CGFloat {
        max(120, anchorBottom - screenBottom - Config.panelGap - 8)
    }

    private func fit(_ content: NSView, below button: NSStatusBarButton?) -> NSView {
        guard let button, let window = button.window else { return content }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let ceiling = HubPanel.availableHeight(anchorBottom: anchor.minY, screenBottom: visible.minY)
        guard content.frame.height > ceiling else { return content }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: content.frame.width, height: ceiling))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = content
        content.frame.origin = .zero
        return scroll
    }

    func show(content raw: NSView, below button: NSStatusBarButton?) {
        let content = fit(raw, below: button)
        let size = content.frame.size
        let stage = FlippedView(frame: NSRect(origin: .zero, size: size))
        content.frame.origin = .zero
        content.autoresizingMask = [.width, .height]
        stage.addSubview(content)
        host.view = stage
        popover.contentSize = size
        guard let button else { return }
        if popover.isShown {
            popover.contentViewController?.view.needsLayout = true
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }
}
