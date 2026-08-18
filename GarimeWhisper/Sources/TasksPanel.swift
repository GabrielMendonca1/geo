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

    static func attributed(
        rows: [TaskRow],
        overflow: Int,
        headerCount: Int,
        footer: String
    ) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: 13)
        let bold = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let small = NSFont.systemFont(ofSize: 11)

        let headerStyle = NSMutableParagraphStyle()
        headerStyle.paragraphSpacing = 10
        let (pre, strong, post) = headerParts(count: headerCount)
        text.append(NSAttributedString(string: pre, attributes: [
            .font: base, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: headerStyle,
        ]))
        text.append(NSAttributedString(string: strong, attributes: [
            .font: bold, .foregroundColor: NSColor.labelColor, .paragraphStyle: headerStyle,
        ]))
        text.append(NSAttributedString(string: post + "\n", attributes: [
            .font: base, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: headerStyle,
        ]))

        let rowStyle = NSMutableParagraphStyle()
        rowStyle.paragraphSpacing = 7
        rowStyle.lineBreakMode = .byTruncatingTail
        for row in rows {
            text.append(NSAttributedString(string: "○  ", attributes: [
                .font: base, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: rowStyle,
            ]))
            text.append(NSAttributedString(string: row.title, attributes: [
                .font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: rowStyle,
            ]))
            if let detail = row.detail {
                text.append(NSAttributedString(string: "  " + detail, attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: rowStyle,
                ]))
            }
            text.append(NSAttributedString(string: "\n", attributes: [
                .font: base, .paragraphStyle: rowStyle,
            ]))
        }
        if overflow > 0 {
            text.append(NSAttributedString(string: "…  e mais \(overflow)\n", attributes: [
                .font: base, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: rowStyle,
            ]))
        }

        let footerStyle = NSMutableParagraphStyle()
        footerStyle.paragraphSpacingBefore = 6
        text.append(NSAttributedString(string: footer, attributes: [
            .font: small, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: footerStyle,
        ]))
        return text
    }

    static func view(_ attributed: NSAttributedString) -> NSView {
        let inset = Config.panelInset
        let textWidth = Config.panelWidth - inset * 2
        let bounds = attributed.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        let height = ceil(bounds.height) + Config.panelVerticalPad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Config.panelWidth, height: height))
        let label = NSTextField(labelWithAttributedString: attributed)
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = textWidth
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: inset,
            y: Config.panelVerticalPad,
            width: textWidth,
            height: ceil(bounds.height)
        )
        container.addSubview(label)
        return container
    }
}
