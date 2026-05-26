import SwiftUI
import UniformTypeIdentifiers

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct BlockDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggedBlockId: UUID?
    @Binding var dropTargetIndex: Int?
    let moveBlock: (UUID, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard draggedBlockId != nil else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            dropTargetIndex = targetIndex
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggedBlockId != nil else { return DropProposal(operation: .cancel) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedId = draggedBlockId else { return false }
        moveBlock(draggedId, targetIndex)
        return true
    }

    func dropExited(info: DropInfo) {
        if dropTargetIndex == targetIndex {
            dropTargetIndex = nil
        }
    }
}

/// Canonical selection. Replaces the historical six-way split across
/// NSTextView.selectedRange / focusCoordinator.activeFocusedBlockId /
/// selectionManager.selectedBlockIds / selectionAnchorId / dragAnchorIndex /
/// document.focusRequest. Read via BlockEventRouter.currentSelection.
///
/// Mirrored back to the legacy stores for backward compat while the
/// migration is partial (Phase 2 boundary).
enum EditorSelection: Equatable {
    case none
    case caret(blockId: UUID, offset: Int)
    case range(blockId: UUID, range: NSRange)
    case blocks(anchorId: UUID, ids: Set<UUID>)

    var primaryBlockId: UUID? {
        switch self {
        case .none: return nil
        case .caret(let id, _), .range(let id, _): return id
        case .blocks(let id, _): return id
        }
    }

    var cursorOffset: Int? {
        switch self {
        case .caret(_, let off): return off
        case .range(_, let r): return r.location + r.length
        case .none, .blocks: return nil
        }
    }

    var isMultiBlock: Bool {
        if case .blocks(_, let ids) = self { return ids.count > 1 }
        return false
    }

    var isEmpty: Bool {
        if case .none = self { return true }
        return false
    }
}

struct SlashState {
    let blockId: UUID
    let blockIndex: Int
    var filter: String
    var selectedIndex: Int
}

struct MentionState {
    let blockId: UUID
    let blockIndex: Int
    var filter: String
    var selectedIndex: Int
}

struct BlockMentionItem: Identifiable, Equatable {
    let id: String
    let title: String
}

struct BlockSlashCommand: Identifiable, Equatable {
    let id: String
    let label: String
    let description: String
    let icon: String
    let section: Section
    let aliases: [String]
    let action: BlockSlashCommandAction

    enum Section: String, CaseIterable {
        case basic = "Basic"
        case list = "Lists"
        case media = "Media"
        case advanced = "Advanced"
        case callout = "Callouts"
    }

    enum BlockSlashCommandAction: Equatable {
        case convertTo(EditorBlockKind)
        case insertDivider
        case insertCallout(CalloutType)
        case insertToggle
        case insertTemplate
        case insertTable
        case insertMathBlock
        case insertCodeBlock
    }

    static let all: [BlockSlashCommand] = [
        BlockSlashCommand(id: "paragraph", label: "Text", description: "Plain text block",
                     icon: "text.alignleft", section: .basic,
                     aliases: ["p", "text", "plain", "paragraph"], action: .convertTo(.paragraph)),
        BlockSlashCommand(id: "h1", label: "Heading 1", description: "Large section heading",
                     icon: "textformat.size.larger", section: .basic,
                     aliases: ["heading1", "title", "h1"], action: .convertTo(.heading(level: 1))),
        BlockSlashCommand(id: "h2", label: "Heading 2", description: "Medium section heading",
                     icon: "textformat.size", section: .basic,
                     aliases: ["heading2", "subtitle", "h2"], action: .convertTo(.heading(level: 2))),
        BlockSlashCommand(id: "h3", label: "Heading 3", description: "Small section heading",
                     icon: "textformat.size.smaller", section: .basic,
                     aliases: ["heading3", "h3"], action: .convertTo(.heading(level: 3))),
        BlockSlashCommand(id: "h4", label: "Heading 4", description: "Sub-section heading",
                     icon: "textformat.size.smaller", section: .basic,
                     aliases: ["heading4", "h4"], action: .convertTo(.heading(level: 4))),
        BlockSlashCommand(id: "h5", label: "Heading 5", description: "Minor heading",
                     icon: "textformat.size.smaller", section: .basic,
                     aliases: ["heading5", "h5"], action: .convertTo(.heading(level: 5))),
        BlockSlashCommand(id: "h6", label: "Heading 6", description: "Smallest heading",
                     icon: "textformat.size.smaller", section: .basic,
                     aliases: ["heading6", "h6"], action: .convertTo(.heading(level: 6))),

        BlockSlashCommand(id: "bullet", label: "Bullet List", description: "Unordered list item",
                     icon: "list.bullet", section: .list,
                     aliases: ["list", "ul", "unordered", "-"], action: .convertTo(.bulletItem(marker: "-"))),
        BlockSlashCommand(id: "numbered", label: "Numbered List", description: "Ordered list item",
                     icon: "list.number", section: .list,
                     aliases: ["number", "ordered", "ol", "1."], action: .convertTo(.orderedItem(number: 1))),
        BlockSlashCommand(id: "todo", label: "To-do", description: "Checkbox task item",
                     icon: "checkmark.square", section: .list,
                     aliases: ["checkbox", "task", "check", "[]"], action: .convertTo(.checkboxItem(checked: false, marker: "-"))),
        BlockSlashCommand(id: "toggle", label: "Toggle", description: "Collapsible section",
                     icon: "chevron.right", section: .list,
                     aliases: ["collapse", "collapsible", "details", "disclosure"], action: .insertToggle),

        BlockSlashCommand(id: "quote", label: "Quote", description: "Block quotation",
                     icon: "text.quote", section: .media,
                     aliases: ["blockquote", "bq", ">"], action: .convertTo(.blockquote)),
        BlockSlashCommand(id: "divider", label: "Divider", description: "Horizontal separator line",
                     icon: "minus", section: .media,
                     aliases: ["hr", "---", "rule", "line", "separator"], action: .insertDivider),
        BlockSlashCommand(id: "code", label: "Code Block", description: "Syntax-highlighted code",
                     icon: "chevron.left.forwardslash.chevron.right", section: .media,
                     aliases: ["codeblock", "```", "fence", "pre", "snippet"], action: .insertCodeBlock),
        BlockSlashCommand(id: "table", label: "Table", description: "Cell-based data table",
                     icon: "tablecells", section: .media,
                     aliases: ["grid", "spreadsheet", "columns"], action: .insertTable),
        BlockSlashCommand(id: "math", label: "Math Block", description: "LaTeX equation",
                     icon: "function", section: .media,
                     aliases: ["equation", "latex", "formula", "$$"], action: .insertMathBlock),

        BlockSlashCommand(id: "template", label: "Template", description: "Insert from template",
                     icon: "doc.on.clipboard", section: .advanced,
                     aliases: ["tmpl", "snippet", "boilerplate"], action: .insertTemplate),

        BlockSlashCommand(id: "callout", label: "Callout", description: "Highlighted note block",
                     icon: "pencil.circle.fill", section: .callout,
                     aliases: ["admonition", "aside"], action: .insertCallout(.note)),
        BlockSlashCommand(id: "tip", label: "Tip", description: "Helpful suggestion",
                     icon: "lightbulb.fill", section: .callout,
                     aliases: ["hint"], action: .insertCallout(.tip)),
        BlockSlashCommand(id: "info", label: "Info", description: "Informational note",
                     icon: "info.circle.fill", section: .callout,
                     aliases: ["information"], action: .insertCallout(.info)),
        BlockSlashCommand(id: "warning", label: "Warning", description: "Caution notice",
                     icon: "exclamationmark.triangle.fill", section: .callout,
                     aliases: ["warn", "caution", "attention"], action: .insertCallout(.warning)),
        BlockSlashCommand(id: "danger", label: "Danger", description: "Critical alert",
                     icon: "xmark.octagon.fill", section: .callout,
                     aliases: ["error", "critical"], action: .insertCallout(.danger)),
        BlockSlashCommand(id: "success", label: "Success", description: "Positive outcome",
                     icon: "checkmark.circle.fill", section: .callout,
                     aliases: ["done", "complete"], action: .insertCallout(.success)),
        BlockSlashCommand(id: "bug", label: "Bug", description: "Bug or issue note",
                     icon: "ladybug.fill", section: .callout,
                     aliases: ["issue", "defect"], action: .insertCallout(.bug)),
        BlockSlashCommand(id: "question", label: "Question", description: "Open question",
                     icon: "questionmark.circle.fill", section: .callout,
                     aliases: ["faq", "ask"], action: .insertCallout(.question)),
        BlockSlashCommand(id: "example", label: "Example", description: "Illustrative example",
                     icon: "list.bullet.rectangle", section: .callout,
                     aliases: ["sample", "demo"], action: .insertCallout(.example)),
        BlockSlashCommand(id: "abstract", label: "Abstract", description: "Summary or overview",
                     icon: "doc.text.fill", section: .callout,
                     aliases: ["summary", "tldr"], action: .insertCallout(.abstract)),
        BlockSlashCommand(id: "slashTodo", label: "Todo Callout", description: "Task reminder",
                     icon: "checklist", section: .callout,
                     aliases: ["reminder"], action: .insertCallout(.todo)),
        BlockSlashCommand(id: "slashNote", label: "Note", description: "General annotation",
                     icon: "pencil.circle.fill", section: .callout,
                     aliases: ["remark", "annotation"], action: .insertCallout(.note)),
    ]
}
