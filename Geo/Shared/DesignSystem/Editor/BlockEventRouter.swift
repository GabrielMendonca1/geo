import SwiftUI
import Observation

@Observable
final class BlockEventRouter {

    let document: BlockEditorDocument
    let focusCoordinator: EditorFocusCoordinator
    let selectionManager: BlockSelectionManager
    var undoManager: UndoManager?
    var mentionableBlocks: [BlockMentionItem]
    var onWikiLinkClicked: ((WikiLinkClickPayload) -> Void)?

    var slashState: SlashState?
    var mentionState: MentionState?
    var isFindPresented: Bool = false
    var templatePickerRequested: Bool = false
    var isApplyingTransaction: Bool = false
    var plugins: [EditorPlugin] = []
    let reconciler: EditorReconciler

    init(
        document: BlockEditorDocument,
        focusCoordinator: EditorFocusCoordinator,
        selectionManager: BlockSelectionManager,
        undoManager: UndoManager? = nil,
        mentionableBlocks: [BlockMentionItem] = [],
        onWikiLinkClicked: ((WikiLinkClickPayload) -> Void)? = nil
    ) {
        self.document = document
        self.focusCoordinator = focusCoordinator
        self.selectionManager = selectionManager
        self.undoManager = undoManager
        self.mentionableBlocks = mentionableBlocks
        self.onWikiLinkClicked = onWikiLinkClicked
        self.reconciler = EditorReconciler()
        self.reconciler.focusCoordinator = focusCoordinator
        self.reconciler.router = self
        let slash = SlashMenuPlugin()
        let mention = MentionMenuPlugin()
        self.plugins = [slash, mention]
        slash.router = self
        mention.router = self
    }

    /// Canonical selection. Computed from the legacy stores (focusCoordinator +
    /// selectionManager + document.focusRequest). Under @Observable tracking,
    /// SwiftUI observers re-render when any of those underlying properties
    /// change — so this stays coherent without an explicit sync step.
    /// Focus wins over selected-block-set when both are present.
    var currentSelection: EditorSelection {
        if let focused = focusCoordinator.activeFocusedBlockId {
            let cursor = document.focusRequest?.cursorOffset ?? 0
            return .caret(blockId: focused, offset: cursor)
        }
        let multi = selectionManager.selectedBlockIds
        if !multi.isEmpty, let anchor = multi.first {
            return .blocks(anchorId: anchor, ids: multi)
        }
        return .none
    }

    /// Canonical selection write. Fans out to the legacy stores so reads of
    /// currentSelection (and any direct reads of focusCoordinator / selectionManager)
    /// remain coherent.
    func setSelection(_ selection: EditorSelection) {
        switch selection {
        case .none:
            selectionManager.clearSelection()
            focusCoordinator.clearActiveFocus()
        case .caret(let id, let cursor):
            selectionManager.clearSelection()
            focusCoordinator.activeFocusedBlockId = id
            document.focusRequest = BlockFocusRequest(blockId: id, cursorOffset: cursor)
        case .range(let id, let r):
            selectionManager.clearSelection()
            focusCoordinator.activeFocusedBlockId = id
            document.focusRequest = BlockFocusRequest(blockId: id, cursorOffset: r.location + r.length)
        case .blocks(_, let ids):
            selectionManager.selectedBlockIds = ids
            focusCoordinator.clearActiveFocus()
        }
    }

    /// Single funnel for state-affecting mutations. Captures pre/post plugin
    /// contexts, applies steps within one structural edit (one undo unit),
    /// reconciles NSTextStorage for affected blocks, then notifies plugins.
    func dispatch(_ tr: EditorTransaction) {
        let oldBlocks = document.blocks
        let oldContext = PluginContext(
            blocks: oldBlocks,
            selection: currentSelection,
            focusedBlockId: focusCoordinator.activeFocusedBlockId
        )
        var selectionAfter = oldContext.selection
        var selectionTouched = false

        document.performStructuralEdit(undoManager: undoManager, name: tr.name, newFocus: nil) { blocks in
            for step in tr.steps {
                let before = selectionAfter
                _ = step.apply(&blocks, selection: &selectionAfter)
                if selectionAfter != before { selectionTouched = true }
            }
        }

        if selectionTouched {
            setSelection(selectionAfter)
        }

        let originatingId: UUID? = tr.steps.compactMap { ($0 as? ReplaceContentStep)?.blockId }.first
        let postEditCaret: (blockId: UUID, caret: Int)? = {
            guard let originatingId, let caret = tr.meta.postEditCaret else { return nil }
            return (blockId: originatingId, caret: caret)
        }()
        reconciler.reconcile(oldBlocks: oldBlocks, newBlocks: document.blocks, excludingBlockId: originatingId, postEditCaret: postEditCaret)

        let newContext = PluginContext(
            blocks: document.blocks,
            selection: currentSelection,
            focusedBlockId: focusCoordinator.activeFocusedBlockId
        )
        for plugin in plugins {
            plugin.onTransaction(tr, oldContext: oldContext, newContext: newContext)
        }
    }

    func handleEvent(_ event: BlockEditorEvent, at index: Int) {
        guard index >= 0, index < document.blocks.count else { return }
        switch event {
        case .contentChange(let content, let spans):
            handleContentChange(content: content, spans: spans, at: index)
        case .focus:
            handleFocus(at: index)
        case .split(let cursorOffset, let after, let spans):
            splitBlock(at: index, cursorOffset: cursorOffset, newBlockContent: after, spans: spans)
        case .delete:
            handleDelete(at: index)
        case .merge(let content, let spans):
            mergeWithPrevious(at: index, content: content, spans: spans)
        case .arrowUp(let offset):
            moveToPreviousBlock(from: index, cursorHint: offset)
        case .arrowDown(let offset):
            moveToNextBlock(from: index, cursorHint: offset)
        case .pasteLines(let lines):
            pasteLines(at: index, lines: lines)
        case .moveUp:
            moveBlockUp(at: index)
        case .moveDown:
            moveBlockDown(at: index)
        case .duplicate:
            duplicateBlock(at: index)
        case .indent:
            indentBlock(at: index)
        case .outdent:
            outdentBlock(at: index)
        case .slashNavigateUp:
            navigateSlashUp()
        case .slashNavigateDown:
            navigateSlashDown()
        case .slashSelect:
            selectSlashCommand(at: index)
        case .slashDismissed:
            slashState = nil
        case .mentionNavigateUp:
            navigateMentionUp()
        case .mentionNavigateDown:
            navigateMentionDown()
        case .mentionSelect:
            selectMention(at: index)
        case .mentionDismissed:
            mentionState = nil
        case .escapeBlock:
            handleEscape(at: index)
        case .convertTo(let kind):
            convertBlock(at: index, to: kind)
        case .selectUp:
            selectionManager.selectBlockUp(from: index, in: document.blocks)
        case .selectDown:
            selectionManager.selectBlockDown(from: index, in: document.blocks)
        case .dragSelectUp:
            handleDragSelectUp(at: index)
        case .dragSelectDown:
            handleDragSelectDown(at: index)
        case .wikiLinkClicked(let payload):
            onWikiLinkClicked?(payload)
        case .findRequested:
            isFindPresented = true
        case .selectAllBlocks:
            selectionManager.selectAll(in: document.blocks)
            focusCoordinator.activeFocusedBlockId = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
            selectionManager.installSelectionMonitor(active: true, blocks: { [document] in document.blocks }, focusCoordinator: focusCoordinator, document: document, undoManager: undoManager)
        case .transaction(let tr):
            dispatch(tr)
        }
    }

    func structuralEdit(_ name: String, focus: BlockFocusRequest?, _ edit: (inout [EditorBlock]) -> Void) {
        document.performStructuralEdit(undoManager: undoManager, name: name, newFocus: focus, edit)
    }

    private func handleFocus(at index: Int) {
        guard let blockId = document.blocks[safe: index]?.id else { return }
        if let s = slashState, s.blockId != blockId { slashState = nil }
        if let m = mentionState, m.blockId != blockId { mentionState = nil }
        focusCoordinator.activeFocusedBlockId = blockId
        selectionManager.clearSelection()
        selectionManager.installSelectionMonitor(active: false, blocks: { [] }, focusCoordinator: focusCoordinator, document: document, undoManager: undoManager)
    }

    private func handleDelete(at index: Int) {
        if selectionManager.selectedBlockIds.count > 1 {
            selectionManager.deleteSelectedBlocks(from: document, undoManager: undoManager)
        } else {
            deleteBlock(at: index)
        }
    }

    private func handleEscape(at index: Int) {
        guard let blockId = document.blocks[safe: index]?.id else { return }
        selectionManager.selectedBlockIds = [blockId]
        focusCoordinator.clearActiveFocus()
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { [selectionManager, focusCoordinator, document, undoManager] in
            selectionManager.installSelectionMonitor(active: true, blocks: { document.blocks }, focusCoordinator: focusCoordinator, document: document, undoManager: undoManager)
        }
    }

    private func handleDragSelectUp(at index: Int) {
        guard let blockId = document.blocks[safe: index]?.id else { return }
        selectionManager.selectedBlockIds = [blockId]
        selectionManager.dragAnchorIndex = index
        selectionManager.selectBlockUp(from: index, in: document.blocks)
        NSApp.keyWindow?.makeFirstResponder(nil)
        selectionManager.installSelectionMonitor(active: true, blocks: { [document] in document.blocks }, focusCoordinator: focusCoordinator, document: document, undoManager: undoManager)
    }

    private func handleDragSelectDown(at index: Int) {
        guard let blockId = document.blocks[safe: index]?.id else { return }
        selectionManager.selectedBlockIds = [blockId]
        selectionManager.dragAnchorIndex = index
        selectionManager.selectBlockDown(from: index, in: document.blocks)
        NSApp.keyWindow?.makeFirstResponder(nil)
        selectionManager.installSelectionMonitor(active: true, blocks: { [document] in document.blocks }, focusCoordinator: focusCoordinator, document: document, undoManager: undoManager)
    }

    func insertTemplateBlocks(markdown: String, at index: Int, cursorOffset: Int?) {
        guard index >= 0, index < document.blocks.count else { return }
        let parsed = MarkdownBlockParser.parse(markdown: markdown)
        guard !parsed.blocks.isEmpty else { return }

        let firstBlock = parsed.blocks[0]
        let remaining = Array(parsed.blocks.dropFirst())

        structuralEdit("Insert Template", focus: BlockFocusRequest(blockId: firstBlock.id, cursorOffset: cursorOffset ?? firstBlock.content.count)) { blocks in
            blocks[index] = firstBlock
            for (i, newBlock) in remaining.enumerated() {
                blocks.insert(newBlock, at: index + 1 + i)
            }
        }
    }

    func toggleCheckbox(at index: Int) {
        guard index >= 0, index < document.blocks.count else { return }
        guard case .checkboxItem(let checked, _) = document.blocks[index].kind else { return }
        let blockId = document.blocks[index].id
        structuralEdit("Toggle Checkbox", focus: nil) { blocks in
            blocks[index] = blocks[index].withCheckedState(!checked)
        }
        document.focusRequest = nil
        focusCoordinator.activeFocusedBlockId = blockId
    }

    func toggleCollapse(at index: Int) {
        guard index >= 0, index < document.blocks.count else { return }
        if case .toggle(let expanded) = document.blocks[index].kind {
            structuralEdit("Toggle Expand", focus: nil) { blocks in
                blocks[index] = blocks[index].withToggleState(expanded: !expanded)
            }
            return
        }
        guard BlockTreeNavigator.hasChildren(index, in: document.blocks) else { return }
        structuralEdit("Toggle Collapse", focus: nil) { blocks in
            blocks[index].collapsed.toggle()
        }
    }

    func appendBlock() {
        let newBlock = EditorBlock.paragraph(content: "")
        structuralEdit("Add Block", focus: BlockFocusRequest(blockId: newBlock.id, cursorOffset: 0)) { blocks in
            blocks.append(newBlock)
        }
    }

    func insertBlock(at index: Int) {
        let newBlock = EditorBlock.paragraph(content: "")
        let safeIndex = min(max(0, index), document.blocks.count)
        structuralEdit("Insert Block", focus: BlockFocusRequest(blockId: newBlock.id, cursorOffset: 0)) { blocks in
            blocks.insert(newBlock, at: min(safeIndex, blocks.count))
        }
    }

    private func resolving(_ id: UUID, _ body: (Int) -> Void) {
        if let i = document.index(of: id) { body(i) }
    }

    func handleEvent(_ event: BlockEditorEvent, on id: UUID) {
        resolving(id) { handleEvent(event, at: $0) }
    }

    func deleteBlock(id: UUID) {
        resolving(id) { deleteBlock(at: $0) }
    }

    func duplicateBlock(id: UUID) {
        resolving(id) { duplicateBlock(at: $0) }
    }

    func moveBlockUp(id: UUID) {
        resolving(id) { moveBlockUp(at: $0) }
    }

    func moveBlockDown(id: UUID) {
        resolving(id) { moveBlockDown(at: $0) }
    }

    func convertBlock(id: UUID, to kind: EditorBlockKind) {
        resolving(id) { convertBlock(at: $0, to: kind) }
    }

    func insertBlock(beforeId id: UUID) {
        resolving(id) { insertBlock(at: $0) }
    }

    func insertBlock(afterId id: UUID) {
        resolving(id) { insertBlock(at: $0 + 1) }
    }

    func indentBlock(id: UUID) {
        resolving(id) { indentBlock(at: $0) }
    }

    func outdentBlock(id: UUID) {
        resolving(id) { outdentBlock(at: $0) }
    }

    func toggleCheckbox(id: UUID) {
        resolving(id) { toggleCheckbox(at: $0) }
    }

    func toggleCollapse(id: UUID) {
        resolving(id) { toggleCollapse(at: $0) }
    }

}
