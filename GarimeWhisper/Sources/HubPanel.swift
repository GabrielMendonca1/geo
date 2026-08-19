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

struct HubRow: Equatable {
    let id: String
    let symbol: String
    let title: String
    let trailing: String?
    let chevron: Bool
    let checkable: Bool
    let tip: String?

    init(
        id: String,
        symbol: String,
        title: String,
        trailing: String?,
        chevron: Bool,
        checkable: Bool,
        tip: String? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.trailing = trailing
        self.chevron = chevron
        self.checkable = checkable
        self.tip = tip
    }
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

    static func tasksSection(_ tasks: [VaultTask], limit: Int, titleLimit: Int) -> HubSection {
        var rows = tasks.prefix(limit).map { task in
            HubRow(
                id: "task:" + task.id,
                symbol: "circle",
                title: truncate(task.title, limit: titleLimit),
                trailing: VaultTasks.dueLabel(task.due),
                chevron: false,
                checkable: false,
                tip: taskTip(task)
            )
        }
        let hidden = tasks.count - rows.count
        if hidden > 0 {
            rows.append(HubRow(
                id: "task:more",
                symbol: "ellipsis",
                title: "e mais \(hidden)",
                trailing: nil,
                chevron: false,
                checkable: false
            ))
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
                id: "project:" + project.path,
                symbol: "circle.dotted",
                title: truncate(project.name, limit: titleLimit),
                trailing: "\(project.todos.count)",
                chevron: true,
                checkable: false
            )
        }
        let hidden = ordered.count - rows.count
        if hidden > 0 {
            rows.append(HubRow(
                id: "project:more",
                symbol: "ellipsis",
                title: "e mais \(hidden)",
                trailing: nil,
                chevron: false,
                checkable: false
            ))
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
            post: " com pendências",
            rows: rows,
            empty: ordered.isEmpty ? "nenhum STATUS.md com todos" : nil
        )
    }

    static func actionSpecs(
        dictating: Bool,
        meeting: Bool,
        call: Bool,
        awake: Bool
    ) -> [HubActionSpec] {
        [
            HubActionSpec(
                action: .dictate,
                symbol: dictating ? "mic.fill" : "mic",
                tooltip: dictating ? "Parar e transcrever (⌥Space)" : "Ditar (⌥Space)",
                on: dictating
            ),
            HubActionSpec(
                action: .meeting,
                symbol: meeting ? "stop.fill" : "recordingtape",
                tooltip: meeting ? "Parar reunião" : "Gravar reunião",
                on: meeting
            ),
            HubActionSpec(
                action: .call,
                symbol: call ? "phone.down.fill" : "phone",
                tooltip: call ? "Parar call" : "Gravar call (com o áudio do outro lado)",
                on: call
            ),
            HubActionSpec(
                action: .insomnia,
                symbol: awake ? "cup.and.saucer.fill" : "cup.and.saucer",
                tooltip: awake ? "Deixar dormir de novo" : "Manter acordado",
                on: awake
            ),
            HubActionSpec(
                action: .notes,
                symbol: "note.text",
                tooltip: "Abrir o Vault",
                on: false
            ),
            HubActionSpec(
                action: .refresh,
                symbol: "arrow.clockwise",
                tooltip: "Atualizar tarefas agora",
                on: false
            ),
        ]
    }

    static func todosSection(_ project: ProjectStatus, titleLimit: Int) -> HubSection {
        let rows = project.todos.map { todo in
            HubRow(
                id: "todo:" + todo,
                symbol: "circle",
                title: truncate(todo, limit: titleLimit),
                trailing: nil,
                chevron: false,
                checkable: true,
                tip: todo
            )
        }
        let strong: String
        switch rows.count {
        case 0: strong = "nenhum todo"
        case 1: strong = "1 todo"
        default: strong = "\(rows.count) todos"
        }
        return HubSection(
            pre: "",
            strong: strong,
            post: rows.count == 1 ? " em aberto" : " em aberto",
            rows: rows,
            empty: rows.isEmpty ? "nada pendente" : nil
        )
    }
}

enum HubInk {
    static let title = NSColor(calibratedWhite: 0.97, alpha: 1)
    static let strong = NSColor(calibratedWhite: 0.95, alpha: 1)
    static let muted = NSColor(calibratedWhite: 1, alpha: 0.48)
    static let body = NSColor(calibratedWhite: 1, alpha: 0.72)
    static let glyph = NSColor(calibratedWhite: 1, alpha: 0.42)
    static let rail = NSColor(calibratedWhite: 1, alpha: 0.16)
    static let faint = NSColor(calibratedWhite: 1, alpha: 0.28)
    static let hover = NSColor(calibratedWhite: 1, alpha: 0.07)
    static let card = NSColor(calibratedWhite: 0.05, alpha: 1)
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
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = hoverFill
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = restingFill
    }

    @objc private func fire() {
        handler?()
    }
}

final class HubRowView: NSView {
    private var handler: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hot = false

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    convenience init(frame: NSRect, handler: (() -> Void)?) {
        self.init(frame: frame)
        self.handler = handler
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard handler != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hot = true
        layer?.backgroundColor = HubInk.hover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hot = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        guard hot else { return }
        handler?()
    }
}

final class HubCardView: NSView {
    override var isFlipped: Bool { true }

    static let noiseTile: NSImage = makeNoiseTile()

    override func draw(_ dirtyRect: NSRect) {
        let radius = Config.panelCornerRadius
        let card = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        HubInk.card.setFill()
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

    private static func makeNoiseTile() -> NSImage {
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            var y: CGFloat = 0
            while y < rect.height {
                var x: CGFloat = 0
                while x < rect.width {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
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

struct HubContent {
    let headerStrong: String
    let headerRest: String
    let back: Bool
    let sections: [HubSection]
    let notice: String?
    let footer: String
    let actions: [HubActionSpec]
}

enum HubPanelView {
    static func build(
        content: HubContent,
        onRow: @escaping (String) -> Void,
        onCheck: @escaping (String) -> Void,
        onBack: @escaping () -> Void,
        onAction: @escaping (HubAction) -> Void,
        onMore: @escaping () -> Void
    ) -> NSView {
        let width = Config.panelWidth
        let inset = Config.panelInset
        let rowHeight = Config.panelRowHeight

        var height = Config.panelTopPad + 22 + Config.panelHeaderGap
        if content.notice != nil { height += 24 }
        for section in content.sections {
            if !section.strong.isEmpty { height += 20 + 8 }
            height += CGFloat(max(section.rows.count, section.empty == nil ? 0 : 1)) * rowHeight
            height += Config.panelSectionGap
        }
        if !content.actions.isEmpty { height += Config.panelActionSize + 14 }
        height += 18 + Config.panelBottomPad

        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = Config.panelTopPad
        var titleX = inset

        if content.back {
            let back = ClosureButton(
                frame: NSRect(x: inset - 6, y: y - 3, width: 26, height: 26),
                handler: onBack
            )
            back.isBordered = false
            back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Voltar")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            back.contentTintColor = HubInk.body
            back.imagePosition = .imageOnly
            back.layer?.cornerRadius = 13
            back.trackHover(resting: .clear, hover: NSColor(calibratedWhite: 1, alpha: 0.12))
            container.addSubview(back)
            titleX = inset + 24
        }

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: content.headerStrong + " ", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: HubInk.title,
        ]))
        title.append(NSAttributedString(string: content.headerRest, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: HubInk.title,
        ]))
        let titleLabel = NSTextField(labelWithAttributedString: title)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.frame = NSRect(x: titleX, y: y, width: width - titleX - inset - 34, height: 22)
        container.addSubview(titleLabel)

        let more = ClosureButton(
            frame: NSRect(x: width - inset - 26, y: y - 2, width: 26, height: 26),
            handler: onMore
        )
        more.isBordered = false
        more.wantsLayer = true
        more.layer?.cornerRadius = 13
        more.trackHover(
            resting: NSColor(calibratedWhite: 0.96, alpha: 1),
            hover: NSColor(calibratedWhite: 1, alpha: 1)
        )
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Ações")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        more.contentTintColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        more.imagePosition = .imageOnly
        container.addSubview(more)
        y += 22 + Config.panelHeaderGap

        if let notice = content.notice {
            let label = NSTextField(labelWithString: notice)
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = HubInk.body
            label.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 16)
            container.addSubview(label)
            y += 24
        }

        for section in content.sections {
            if !section.strong.isEmpty {
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
            }

            if section.rows.isEmpty, let empty = section.empty {
                let label = NSTextField(labelWithString: empty)
                label.font = NSFont.systemFont(ofSize: 13)
                label.textColor = HubInk.faint
                label.frame = NSRect(
                    x: Config.panelTextX,
                    y: y + 8,
                    width: width - Config.panelTextX - inset,
                    height: 18
                )
                container.addSubview(label)
                y += rowHeight
            }

            for row in section.rows {
                let clickable = row.chevron
                let holder = HubRowView(
                    frame: NSRect(x: inset - 8, y: y, width: width - inset * 2 + 16, height: rowHeight),
                    handler: clickable ? { onRow(row.id) } : nil
                )
                container.addSubview(holder)

                let rail = NSView(frame: NSRect(x: 8, y: 7, width: 2, height: rowHeight - 14))
                rail.wantsLayer = true
                rail.layer?.backgroundColor = HubInk.rail.cgColor
                rail.layer?.cornerRadius = 1
                holder.addSubview(rail)

                let glyphFrame = NSRect(
                    x: Config.panelGlyphX - inset + 8,
                    y: (rowHeight - 18) / 2,
                    width: 18,
                    height: 18
                )
                if row.checkable {
                    let check = ClosureButton(frame: glyphFrame) { onCheck(row.id) }
                    check.isBordered = false
                    check.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Concluir")?
                        .withSymbolConfiguration(.init(pointSize: 14, weight: .light))
                    check.alternateImage = NSImage(
                        systemSymbolName: "checkmark.circle.fill",
                        accessibilityDescription: nil
                    )?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
                    check.setButtonType(.momentaryChange)
                    check.contentTintColor = HubInk.glyph
                    check.imagePosition = .imageOnly
                    check.toolTip = row.tip.map { $0 + " — clique para marcar como feito" }
                        ?? "Marcar como feito"
                    check.trackHover(
                        resting: .clear,
                        hover: NSColor(calibratedWhite: 1, alpha: 0.12)
                    )
                    holder.addSubview(check)
                } else {
                    let glyph = NSImageView(frame: glyphFrame)
                    glyph.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 14, weight: .light))
                    glyph.contentTintColor = HubInk.glyph
                    holder.addSubview(glyph)
                }

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
                let textX = Config.panelTextX - inset + 8
                label.frame = NSRect(
                    x: textX,
                    y: (rowHeight - 18) / 2,
                    width: holder.bounds.width - textX - (row.chevron ? 26 : 10),
                    height: 18
                )
                holder.addSubview(label)
                if let tip = row.tip { holder.toolTip = tip }

                if row.chevron {
                    let arrow = NSImageView(frame: NSRect(
                        x: holder.bounds.width - 24,
                        y: (rowHeight - 14) / 2,
                        width: 14,
                        height: 14
                    ))
                    arrow.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
                    arrow.contentTintColor = HubInk.faint
                    holder.addSubview(arrow)
                }

                y += rowHeight
            }
            y += Config.panelSectionGap
        }

        if !content.actions.isEmpty {
            var x = inset
            for spec in content.actions {
                let button = ClosureButton(
                    frame: NSRect(x: x, y: y, width: Config.panelActionSize, height: Config.panelActionSize),
                    handler: { onAction(spec.action) }
                )
                button.isBordered = false
                button.wantsLayer = true
                button.layer?.cornerRadius = Config.panelActionSize / 2
                button.trackHover(
                    resting: spec.on
                        ? NSColor(calibratedWhite: 0.95, alpha: 1)
                        : NSColor(calibratedWhite: 1, alpha: 0.09),
                    hover: spec.on
                        ? NSColor(calibratedWhite: 1, alpha: 1)
                        : NSColor(calibratedWhite: 1, alpha: 0.2)
                )
                button.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.tooltip)?
                    .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
                button.contentTintColor = spec.on
                    ? NSColor(calibratedWhite: 0.06, alpha: 1)
                    : HubInk.body
                button.imagePosition = .imageOnly
                button.toolTip = spec.tooltip
                container.addSubview(button)
                x += Config.panelActionSize + 10
            }
            y += Config.panelActionSize + 14
        }

        let stamp = NSTextField(labelWithString: content.footer)
        stamp.font = NSFont.systemFont(ofSize: 11)
        stamp.textColor = HubInk.faint
        stamp.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 16)
        container.addSubview(stamp)

        return container
    }
}

final class HubPanel {
    private var panel: NSPanel?
    private var monitor: Any?

    var isOpen: Bool { panel?.isVisible ?? false }

    func show(content: NSView, below button: NSStatusBarButton?) {
        let size = content.frame.size
        let host = HubCardView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.addSubview(content)

        if let panel {
            panel.setContentSize(size)
            panel.contentView = host
            panel.setFrameOrigin(origin(for: size, below: button))
            return
        }

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
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.level = .popUpMenu
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let target = origin(for: size, below: button)
        window.setFrameOrigin(NSPoint(x: target.x, y: target.y + Config.panelSlideRise))
        window.alphaValue = 0
        window.orderFrontRegardless()
        panel = window

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Config.panelFadeSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 1
            window.animator().setFrameOrigin(target)
        }

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
