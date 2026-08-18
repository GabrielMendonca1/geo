import AppKit

struct TaskRow: Equatable {
    let title: String
    let detail: String?
}

enum TasksPanel {
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let head = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return head + "…"
    }

    static func rows(_ tasks: [VaultTask], limit: Int, titleLimit: Int) -> ([TaskRow], Int) {
        let shown = tasks.prefix(limit).map { task in
            TaskRow(
                title: truncate(task.title, limit: titleLimit),
                detail: VaultTasks.dueLabel(task.due)
            )
        }
        return (Array(shown), max(0, tasks.count - limit))
    }

    static func headerParts(count: Int) -> (String, String, String) {
        if count == 0 { return ("Você não tem ", "tarefas", " abertas") }
        if count == 1 { return ("Você tem ", "1 tarefa", " aberta") }
        return ("Você tem ", "\(count) tarefas", " abertas")
    }

    static func headerLabel(count: Int) -> NSTextField {
        let (pre, strong, post) = headerParts(count: count)
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: pre, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        text.append(NSAttributedString(string: strong, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]))
        text.append(NSAttributedString(string: post, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return NSTextField(labelWithAttributedString: text)
    }

    static func rowLabel(_ row: TaskRow) -> NSTextField {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: row.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        if let detail = row.detail {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    static func dash(y: CGFloat) -> NSView {
        let mark = NSView(frame: NSRect(x: Config.panelInset, y: y, width: 2, height: 13))
        mark.wantsLayer = true
        mark.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        mark.layer?.cornerRadius = 1
        return mark
    }

    static func circle(x: CGFloat, y: CGFloat) -> NSView {
        let image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        let imageView = NSImageView(frame: NSRect(x: x, y: y, width: 15, height: 15))
        imageView.image = image
        imageView.contentTintColor = .tertiaryLabelColor
        return imageView
    }

    static func view(
        rows: [TaskRow],
        overflow: Int,
        headerCount: Int,
        footer: String
    ) -> NSView {
        let inset = Config.panelInset
        let rowHeight = Config.panelRowHeight
        let width = Config.panelWidth
        let circleX = inset + 14
        let textX = circleX + 24
        var extraLines: CGFloat = 0
        if overflow > 0 { extraLines += 1 }
        let height = Config.panelVerticalPad * 2
            + 22 + 10
            + CGFloat(rows.count) * rowHeight
            + extraLines * 22
            + 22
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        var y = height - Config.panelVerticalPad - 20
        let header = headerLabel(count: headerCount)
        header.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 18)
        container.addSubview(header)
        y -= 10

        for row in rows {
            y -= rowHeight
            container.addSubview(dash(y: y + (rowHeight - 13) / 2))
            container.addSubview(circle(x: circleX, y: y + (rowHeight - 15) / 2))
            let label = rowLabel(row)
            label.frame = NSRect(
                x: textX,
                y: y + (rowHeight - 17) / 2,
                width: width - textX - inset,
                height: 17
            )
            container.addSubview(label)
        }

        if overflow > 0 {
            y -= 22
            let more = NSTextField(labelWithString: "e mais \(overflow)…")
            more.font = NSFont.systemFont(ofSize: 12)
            more.textColor = .tertiaryLabelColor
            more.frame = NSRect(x: textX, y: y, width: width - textX - inset, height: 16)
            container.addSubview(more)
        }

        y -= 22
        let stamp = NSTextField(labelWithString: footer)
        stamp.font = NSFont.systemFont(ofSize: 11)
        stamp.textColor = .tertiaryLabelColor
        stamp.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 14)
        container.addSubview(stamp)

        return container
    }
}
