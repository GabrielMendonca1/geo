import SwiftUI
import Observation
import os.log

private let pasteLinesLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "BlockEventRouter")

@Observable
final class BlockEventRouter {
    private static let pasteLineCap = 500

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
        reconciler.reconcile(oldBlocks: oldBlocks, newBlocks: document.blocks, excludingBlockId: originatingId)

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

    private func structuralEdit(_ name: String, focus: BlockFocusRequest?, _ edit: (inout [EditorBlock]) -> Void) {
        document.performStructuralEdit(undoManager: undoManager, name: name, newFocus: focus, edit)
    }

    private func handleContentChange(content: String, spans: [InlineSpan], at index: Int) {
        selectionManager.clearSelection()
        if case .table = document.blocks[index].kind {
            let blockId = document.blocks[index].id
            structuralEdit("Edit Table", focus: nil) { blocks in
                guard index < blocks.count else { return }
                let raw = content
                blocks[index] = EditorBlock(
                    id: blockId, kind: .table,
                    sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                    rawText: raw, indent: "", prefix: "",
                    contentRange: NSRange(location: 0, length: (raw as NSString).length)
                )
            }
            return
        }
        if case .callout = document.blocks[index].kind {
            let block = document.blocks[index]
            let updated = block.withCalloutContent(content)
            structuralEdit("Edit Callout", focus: nil) { blocks in
                guard index < blocks.count else { return }
                blocks[index] = updated
            }
            return
        }
        if case .toggle = document.blocks[index].kind {
            let block = document.blocks[index]
            let updated = block.withToggleContent(content)
            structuralEdit("Edit Toggle", focus: nil) { blocks in
                guard index < blocks.count else { return }
                blocks[index] = updated
            }
            return
        }
        if case .mathBlock = document.blocks[index].kind {
            let block = document.blocks[index]
            let updated = block.withMathContent(content)
            structuralEdit("Edit Math Block", focus: nil) { blocks in
                guard index < blocks.count else { return }
                blocks[index] = updated
            }
            return
        }
        document.updateBlockContent(at: index, content: content, spans: spans)
        guard index < document.blocks.count else { return }
        if case .paragraph = document.blocks[index].kind {
            if content.contains("\n") {
                var lines = content.components(separatedBy: "\n")
                while lines.last?.isEmpty == true && lines.count > 1 { lines.removeLast() }
                if lines.count > 1 {
                    pasteLines(at: index, lines: lines)
                    return
                }
            }
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if MarkdownBlockParser.isHorizontalRule(trimmed) {
                let blockId = document.blocks[index].id
                let newBlock = EditorBlock.paragraph(content: "")
                structuralEdit("Horizontal Rule", focus: BlockFocusRequest(blockId: newBlock.id, cursorOffset: 0)) { blocks in
                    guard index < blocks.count else { return }
                    var divider = EditorBlock.divider()
                    divider.id = blockId
                    blocks[index] = divider
                    blocks.insert(newBlock, at: index + 1)
                }
            } else if let img = MarkdownBlockParser.parseImageMarkdown(content) {
                let blockId = document.blocks[index].id
                let newBlock = EditorBlock.paragraph(content: "")
                structuralEdit("Insert Image", focus: BlockFocusRequest(blockId: newBlock.id, cursorOffset: 0)) { blocks in
                    guard index < blocks.count else { return }
                    let raw = "![\(img.alt)](\(img.url))\n"
                    blocks[index] = EditorBlock(
                        id: blockId, kind: .image(alt: img.alt, url: img.url),
                        sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                        rawText: raw, indent: "", prefix: "",
                        contentRange: NSRange(location: 0, length: (raw as NSString).length - 1)
                    )
                    blocks.insert(newBlock, at: index + 1)
                }
            } else if let outcome = BlockPrefixDetector.detect(content) {
                let blockId = document.blocks[index].id
                slashState = nil
                mentionState = nil
                switch outcome {
                case .convert(let kind, let remainingContent):
                    structuralEdit("Auto Format", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                        guard index < blocks.count else { return }
                        blocks[index] = blocks[index]
                            .withContent(remainingContent, spans: [])
                            .withKind(kind)
                    }
                case .insertCodeBlock:
                    let raw = "```\n\n```\n"
                    let codeBlock = EditorBlock(
                        id: blockId, kind: .codeBlock(language: nil),
                        sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                        rawText: raw, indent: "", prefix: "",
                        contentRange: NSRange(location: 4, length: 0)
                    )
                    structuralEdit("Auto Format Code Block", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                        guard index < blocks.count else { return }
                        blocks[index] = codeBlock
                    }
                case .insertMathBlock:
                    var mathBlock = EditorBlock.mathBlock()
                    mathBlock.id = blockId
                    structuralEdit("Auto Format Math Block", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                        guard index < blocks.count else { return }
                        blocks[index] = mathBlock
                    }
                }
            }
        }
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

    private func splitBlock(at index: Int, cursorOffset: Int, newBlockContent: String, spans: [InlineSpan]) {
        guard index >= 0, index < document.blocks.count else { return }
        let current = document.blocks[index]

        let effectiveContent: String = {
            if case .callout = current.kind { return current.calloutContent ?? "" }
            if case .toggle = current.kind { return current.toggleContent ?? "" }
            return current.content
        }()

        if newBlockContent.isEmpty && effectiveContent.isEmpty && current.exitsOnEmptyEnter {
            let converted = ConvertBlockCommand(
                blockIndex: index,
                originalBlock: current,
                convertedBlock: {
                    var para = EditorBlock.paragraph(content: "")
                    para.id = current.id
                    return para
                }()
            )
            document.executeCommand(converted, undoManager: undoManager)
            return
        }

        let truncated: String = {
            let full = current.content as NSString
            let clamped = max(0, min(cursorOffset, full.length))
            return full.substring(to: clamped)
        }()

        let truncatedSpans = InlineSpan.split(spans: current.spans, at: (truncated as NSString).length).before
        let newBlock = current.continuationBlock(content: newBlockContent, spans: spans)

        let updatedBlock: EditorBlock = {
            if case .empty = current.kind {
                var para = EditorBlock.paragraph(content: "")
                para.id = current.id
                return para
            } else {
                return current.withContent(truncated, spans: truncatedSpans)
            }
        }()

        let command = SplitBlockCommand(
            blockIndex: index,
            originalBlock: current,
            updatedBlock: updatedBlock,
            newBlock: newBlock
        )
        document.executeCommand(command, undoManager: undoManager)
    }

    func deleteBlock(at index: Int) {
        guard index >= 0, index < document.blocks.count else { return }
        guard document.blocks.count > 1 else {
            let emptyBlock = EditorBlock.empty()
            structuralEdit("Delete Block", focus: BlockFocusRequest(blockId: emptyBlock.id, cursorOffset: 0)) { blocks in
                blocks[0] = emptyBlock
            }
            return
        }
        let subtree = BlockTreeNavigator.subtreeRange(of: index, in: document.blocks)
        let targetId: UUID
        let targetOffset: Int
        if index > 0 {
            targetId = document.blocks[index - 1].id
            targetOffset = document.blocks[index - 1].content.count
        } else if subtree.upperBound < document.blocks.count {
            targetId = document.blocks[subtree.upperBound].id
            targetOffset = 0
        } else {
            targetId = document.blocks[0].id
            targetOffset = 0
        }
        let deletedBlocks = Array(document.blocks[subtree])
        let command = DeleteBlockCommand(
            blockIndex: subtree.lowerBound,
            deletedBlocks: deletedBlocks,
            focusRequest: BlockFocusRequest(blockId: targetId, cursorOffset: targetOffset)
        )
        document.executeCommand(command, undoManager: undoManager)
    }

    private func mergeWithPrevious(at index: Int, content: String, spans: [InlineSpan]) {
        guard index > 0 else { return }
        let prevBlock = document.blocks[index - 1]
        let currentBlock = document.blocks[index]
        let rejectAndResync: () -> Void = { [document] in
            document.focusRequest = BlockFocusRequest(blockId: currentBlock.id, cursorOffset: 0)
            document.editGeneration &+= 1
        }
        switch prevBlock.kind {
        case .horizontalRule, .codeBlock, .table, .image, .callout, .toggle, .mathBlock:
            rejectAndResync()
            return
        case .heading:
            switch currentBlock.kind {
            case .bulletItem, .orderedItem, .checkboxItem:
                rejectAndResync()
                return
            default:
                break
            }
        default:
            break
        }
        let prevContent = prevBlock.content
        let shiftedSpans = InlineSpan.shifted(spans, by: prevContent.count)
        let mergedSpans = prevBlock.spans + shiftedSpans
        let mergedContent = prevContent + content
        let mergedBlock = prevBlock.withContent(mergedContent, spans: mergedSpans)
        let command = MergeBlockCommand(
            blockIndex: index,
            originalPrevBlock: prevBlock,
            originalBlock: currentBlock,
            mergedBlock: mergedBlock,
            cursorOffset: prevContent.count
        )
        document.executeCommand(command, undoManager: undoManager)
    }

    private func moveToPreviousBlock(from index: Int, cursorHint: Int) {
        var i = index - 1
        while i >= 0 {
            if !BlockSelectionManager.isNonEditable(document.blocks[i].kind) {
                let prev = document.blocks[i]
                let offset = min(cursorHint, prev.content.count)
                document.focusRequest = BlockFocusRequest(blockId: prev.id, cursorOffset: offset)
                return
            }
            i -= 1
        }
    }

    private func moveToNextBlock(from index: Int, cursorHint: Int) {
        var i = index + 1
        while i < document.blocks.count {
            if !BlockSelectionManager.isNonEditable(document.blocks[i].kind) {
                let next = document.blocks[i]
                let offset = min(cursorHint, next.content.count)
                document.focusRequest = BlockFocusRequest(blockId: next.id, cursorOffset: offset)
                return
            }
            i += 1
        }
    }

    func moveBlockUp(at index: Int) {
        guard index > 0, index < document.blocks.count else { return }
        let blockId = document.blocks[index].id
        let snapshotBefore = document.blocks
        let subtree = BlockTreeNavigator.subtreeRange(of: index, in: document.blocks)
        let targetIndex = subtree.lowerBound - 1
        guard targetIndex >= 0 else { return }
        let targetSubtree = BlockTreeNavigator.subtreeRange(of: targetIndex, in: document.blocks)
        var afterBlocks = snapshotBefore
        if document.blocks[targetIndex].depth == document.blocks[index].depth {
            let movingSlice = Array(afterBlocks[subtree])
            let targetSlice = Array(afterBlocks[targetSubtree])
            afterBlocks.replaceSubrange(targetSubtree.lowerBound..<subtree.upperBound,
                                        with: movingSlice + targetSlice)
        } else {
            let movingSlice = Array(afterBlocks[subtree])
            afterBlocks.removeSubrange(subtree)
            let insertAt = min(targetSubtree.lowerBound, afterBlocks.count)
            afterBlocks.insert(contentsOf: movingSlice, at: insertAt)
        }
        document.executeCommand(MoveBlockCommand(
            snapshotBefore: snapshotBefore,
            snapshotAfter: afterBlocks,
            focusBlockId: blockId
        ), undoManager: undoManager)
    }

    func moveBlockDown(at index: Int) {
        guard index >= 0, index < document.blocks.count else { return }
        let blockId = document.blocks[index].id
        let snapshotBefore = document.blocks
        let subtree = BlockTreeNavigator.subtreeRange(of: index, in: document.blocks)
        guard subtree.upperBound < document.blocks.count else { return }
        let targetIndex = subtree.upperBound
        let targetSubtree = BlockTreeNavigator.subtreeRange(of: targetIndex, in: document.blocks)
        var afterBlocks = snapshotBefore
        if document.blocks[targetIndex].depth == document.blocks[index].depth {
            let movingSlice = Array(afterBlocks[subtree])
            let targetSlice = Array(afterBlocks[targetSubtree])
            afterBlocks.replaceSubrange(subtree.lowerBound..<targetSubtree.upperBound,
                                        with: targetSlice + movingSlice)
        } else {
            let movingSlice = Array(afterBlocks[subtree])
            afterBlocks.removeSubrange(subtree)
            let insertAt = min(targetSubtree.upperBound - subtree.count, afterBlocks.count)
            afterBlocks.insert(contentsOf: movingSlice, at: insertAt)
        }
        document.executeCommand(MoveBlockCommand(
            snapshotBefore: snapshotBefore,
            snapshotAfter: afterBlocks,
            focusBlockId: blockId
        ), undoManager: undoManager)
    }

    func duplicateBlock(at index: Int) {
        guard index >= 0, index < document.blocks.count else { return }
        let subtree = BlockTreeNavigator.subtreeRange(of: index, in: document.blocks)
        let copies = document.blocks[subtree].map { block -> EditorBlock in
            var copy = block
            copy.id = UUID()
            return copy
        }
        let firstCopyId = copies[0].id
        structuralEdit("Duplicate", focus: BlockFocusRequest(blockId: firstCopyId, cursorOffset: 0)) { blocks in
            blocks.insert(contentsOf: copies, at: subtree.upperBound)
        }
    }

    func convertBlock(at index: Int, to kind: EditorBlockKind) {
        guard index >= 0, index < document.blocks.count else { return }
        let block = document.blocks[index]
        if case .toggle(let expanded) = kind {
            let existingContent: String = {
                if case .toggle = block.kind { return block.toggleContent ?? "" }
                if case .callout = block.kind { return block.calloutContent ?? "" }
                return block.content
            }()
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                var toggle = EditorBlock.toggle(title: "", content: existingContent, expanded: expanded)
                toggle.id = block.id
                blocks[index] = toggle
            }
            return
        }
        if case .toggle = block.kind {
            let toggleTitle = block.toggleTitle ?? ""
            let toggleBody = block.toggleContent ?? ""
            if case .callout(let type, let incomingTitle) = kind {
                let finalTitle = incomingTitle ?? (toggleTitle.isEmpty ? nil : toggleTitle)
                let existingContent = toggleBody
                structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                    var callout = EditorBlock.callout(type: type, title: finalTitle, content: existingContent)
                    callout.id = block.id
                    blocks[index] = callout
                }
                return
            }
            let existingContent: String = {
                if toggleTitle.isEmpty { return toggleBody }
                if toggleBody.isEmpty { return toggleTitle }
                return toggleTitle + "\n" + toggleBody
            }()
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                let raw = existingContent + "\n"
                var newBlock = EditorBlock(
                    id: block.id, kind: kind,
                    sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                    rawText: raw, indent: "", prefix: "",
                    contentRange: NSRange(location: 0, length: (existingContent as NSString).length)
                )
                newBlock.cleanContent = existingContent
                if let prefixed = Self.convertedBlock(content: existingContent, kind: kind) {
                    var result = prefixed
                    result.id = block.id
                    blocks[index] = result
                } else {
                    blocks[index] = newBlock
                }
            }
            return
        }
        if case .callout(let type, let title) = kind {
            let existingContent: String = {
                if case .callout = block.kind { return block.calloutContent ?? "" }
                return block.content
            }()
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                var callout = EditorBlock.callout(type: type, title: title, content: existingContent)
                callout.id = block.id
                blocks[index] = callout
            }
            return
        }
        if case .callout = block.kind {
            let existingContent = block.calloutContent ?? ""
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                let raw = existingContent + "\n"
                var newBlock = EditorBlock(
                    id: block.id, kind: kind,
                    sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                    rawText: raw, indent: "", prefix: "",
                    contentRange: NSRange(location: 0, length: (existingContent as NSString).length)
                )
                newBlock.cleanContent = existingContent
                if let prefixed = Self.convertedBlock(content: existingContent, kind: kind) {
                    var result = prefixed
                    result.id = block.id
                    blocks[index] = result
                } else {
                    blocks[index] = newBlock
                }
            }
            return
        }
        if case .mathBlock = kind {
            let existingContent: String = {
                if case .mathBlock = block.kind { return block.mathContent ?? "" }
                return block.content
            }()
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                var math = EditorBlock.mathBlock(latex: existingContent)
                math.id = block.id
                blocks[index] = math
            }
            return
        }
        if case .mathBlock = block.kind {
            let existingContent = block.mathContent ?? ""
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                if let prefixed = Self.convertedBlock(content: existingContent, kind: kind) {
                    var result = prefixed
                    result.id = block.id
                    blocks[index] = result
                } else {
                    blocks[index] = EditorBlock.paragraph(content: existingContent)
                }
            }
            return
        }
        if case .codeBlock = block.kind {
            let existingContent = block.codeContent ?? ""
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                if let prefixed = Self.convertedBlock(content: existingContent, kind: kind) {
                    var result = prefixed
                    result.id = block.id
                    blocks[index] = result
                } else {
                    var paragraph = EditorBlock.paragraph(content: existingContent)
                    paragraph.id = block.id
                    blocks[index] = paragraph
                }
            }
            return
        }
        document.executeCommand(ConvertBlockCommand(
            blockIndex: index,
            originalBlock: block,
            convertedBlock: block.withKind(kind)
        ), undoManager: undoManager)
    }

    private static func convertedBlock(content: String, kind: EditorBlockKind) -> EditorBlock? {
        switch kind {
        case .paragraph:
            return EditorBlock.paragraph(content: content)
        default:
            var block = EditorBlock.paragraph(content: content)
            let converted = block.withKind(kind)
            return converted
        }
    }

    private func indentBlock(at index: Int) {
        guard index >= 0, index < document.blocks.count else { return }
        let block = document.blocks[index]
        switch block.kind {
        case .bulletItem, .orderedItem, .checkboxItem:
            guard Self.hasListAncestor(of: index, in: document.blocks) else { return }
            let subtree = BlockTreeNavigator.subtreeRange(of: index, in: document.blocks)
            structuralEdit("Indent", focus: nil) { blocks in
                for i in subtree {
                    blocks[i] = blocks[i].withIndent(blocks[i].indent + "  ")
                }
            }
        default:
            break
        }
    }

    private static func hasListAncestor(of index: Int, in blocks: [EditorBlock]) -> Bool {
        let d = blocks[index].depth
        var i = index - 1
        while i >= 0 {
            if blocks[i].depth <= d {
                switch blocks[i].kind {
                case .bulletItem, .orderedItem, .checkboxItem: return true
                default: return false
                }
            }
            i -= 1
        }
        return false
    }

    private func outdentBlock(at index: Int) {
        guard index >= 0, index < document.blocks.count else { return }
        let block = document.blocks[index]
        guard !block.indent.isEmpty else { return }
        switch block.kind {
        case .bulletItem, .orderedItem, .checkboxItem:
            guard let parentIdx = BlockTreeNavigator.parent(of: index, in: document.blocks) else { return }
            let subtree = BlockTreeNavigator.subtreeRange(of: index, in: document.blocks)
            let parentSubtree = BlockTreeNavigator.subtreeRange(of: parentIdx, in: document.blocks)
            let followingSiblingStart = subtree.upperBound
            let followingSiblingEnd = parentSubtree.upperBound
            structuralEdit("Outdent", focus: nil) { blocks in
                for i in subtree {
                    var newIndent = blocks[i].indent
                    if newIndent.hasSuffix("  ") {
                        newIndent = String(newIndent.dropLast(2))
                    } else if newIndent.hasSuffix("\t") {
                        newIndent = String(newIndent.dropLast(1))
                    } else if !newIndent.isEmpty {
                        newIndent = String(newIndent.dropLast(1))
                    }
                    blocks[i] = blocks[i].withIndent(newIndent)
                }
                if followingSiblingStart < followingSiblingEnd {
                    for i in followingSiblingStart..<followingSiblingEnd {
                        blocks[i] = blocks[i].withIndent(blocks[i].indent + "  ")
                    }
                }
            }
        default:
            break
        }
    }

    private func pasteLines(at index: Int, lines: [String]) {
        guard !lines.isEmpty, index >= 0, index < document.blocks.count else { return }

        let capped: [String]
        if lines.count > Self.pasteLineCap {
            pasteLinesLogger.warning("paste truncated: \(lines.count) lines → \(Self.pasteLineCap) (cap)")
            capped = Array(lines.prefix(Self.pasteLineCap))
        } else {
            capped = lines
        }

        let firstContent = capped[0]
        let remaining = Array(capped.dropFirst())
        let remainingMD = remaining.map { $0 + "\n" }.joined()
        let parsed = remaining.isEmpty ? [] : MarkdownBlockParser.parse(markdown: remainingMD).blocks
        let currentBlockId = document.blocks[index].id

        let focusTarget: EditorSelection
        if let last = parsed.last {
            focusTarget = .caret(blockId: last.id, offset: last.content.count)
        } else {
            focusTarget = .caret(blockId: currentBlockId, offset: firstContent.count)
        }

        var steps: [EditorStep] = [
            ReplaceContentStep(blockId: currentBlockId, content: firstContent, spans: [])
        ]
        if !parsed.isEmpty {
            steps.append(InsertBlocksStep(at: index + 1, blocks: parsed))
        }
        steps.append(SetSelectionStep(newSelection: focusTarget))

        dispatch(EditorTransaction(name: "Paste", steps: steps))
    }

    private func navigateSlashUp() {
        guard slashState != nil else { return }
        let count = SlashCommandOverlay.filtered(for: slashState!.blockId, slashState: slashState).count
        if count > 0 {
            slashState!.selectedIndex = (slashState!.selectedIndex - 1 + count) % count
        }
    }

    private func navigateSlashDown() {
        guard slashState != nil else { return }
        let count = SlashCommandOverlay.filtered(for: slashState!.blockId, slashState: slashState).count
        if count > 0 {
            slashState!.selectedIndex = (slashState!.selectedIndex + 1) % count
        }
    }

    private func selectSlashCommand(at index: Int) {
        guard let state = slashState else { return }
        let commands = SlashCommandOverlay.filtered(for: state.blockId, slashState: slashState)
        guard state.selectedIndex < commands.count else { return }
        executeBlockSlashCommand(commands[state.selectedIndex], at: index)
    }

    func executeBlockSlashCommand(_ command: BlockSlashCommand, at index: Int) {
        slashState = nil
        guard index >= 0, index < document.blocks.count else { return }

        switch command.action {
        case .convertTo(let kind):
            let blockId = document.blocks[index].id
            structuralEdit("Slash Command", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                blocks[index] = blocks[index].withContent("").withKind(kind)
            }
        case .insertDivider:
            let blockId = document.blocks[index].id
            let newBlock = EditorBlock.paragraph(content: "")
            structuralEdit("Insert Divider", focus: BlockFocusRequest(blockId: newBlock.id, cursorOffset: 0)) { blocks in
                var divider = EditorBlock.divider()
                divider.id = blockId
                blocks[index] = divider
                blocks.insert(newBlock, at: index + 1)
            }
        case .insertCallout(let calloutType):
            let blockId = document.blocks[index].id
            structuralEdit("Insert Callout", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                var callout = EditorBlock.callout(type: calloutType)
                callout.id = blockId
                blocks[index] = callout
            }
        case .insertToggle:
            let blockId = document.blocks[index].id
            structuralEdit("Insert Toggle", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                var toggle = EditorBlock.toggle(expanded: true)
                toggle.id = blockId
                blocks[index] = toggle
            }
        case .insertTemplate:
            structuralEdit("Clear Slash", focus: BlockFocusRequest(blockId: document.blocks[index].id, cursorOffset: 0)) { blocks in
                blocks[index] = blocks[index].withContent("")
            }
            templatePickerRequested = true
        case .insertTable:
            let blockId = document.blocks[index].id
            let tableMarkdown = TableModel.defaultTable().serialize()
            let newBlock = EditorBlock.paragraph(content: "")
            structuralEdit("Insert Table", focus: nil) { blocks in
                let raw = tableMarkdown
                blocks[index] = EditorBlock(
                    id: blockId, kind: .table,
                    sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                    rawText: raw, indent: "", prefix: "",
                    contentRange: NSRange(location: 0, length: (raw as NSString).length)
                )
                blocks.insert(newBlock, at: index + 1)
            }
        case .insertMathBlock:
            let mathBlock = EditorBlock.mathBlock()
            structuralEdit("Insert Math Block", focus: BlockFocusRequest(blockId: mathBlock.id, cursorOffset: 0)) { blocks in
                blocks[index] = mathBlock
            }
        case .insertCodeBlock:
            let raw = "```\n\n```\n"
            let codeBlock = EditorBlock(
                id: UUID(), kind: .codeBlock(language: nil),
                sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                rawText: raw, indent: "", prefix: "",
                contentRange: NSRange(location: 4, length: 0)
            )
            structuralEdit("Insert Code Block", focus: BlockFocusRequest(blockId: codeBlock.id, cursorOffset: 0)) { blocks in
                blocks[index] = codeBlock
            }
        }
    }

    private func navigateMentionUp() {
        guard mentionState != nil else { return }
        let count = MentionOverlay.filtered(mentionState: mentionState, mentionableBlocks: mentionableBlocks).count
        if count > 0 {
            mentionState!.selectedIndex = (mentionState!.selectedIndex - 1 + count) % count
        }
    }

    private func navigateMentionDown() {
        guard mentionState != nil else { return }
        let count = MentionOverlay.filtered(mentionState: mentionState, mentionableBlocks: mentionableBlocks).count
        if count > 0 {
            mentionState!.selectedIndex = (mentionState!.selectedIndex + 1) % count
        }
    }

    private func selectMention(at index: Int) {
        guard let state = mentionState else { return }
        let mentions = MentionOverlay.filtered(mentionState: mentionState, mentionableBlocks: mentionableBlocks)
        guard state.selectedIndex < mentions.count else { return }
        executeMention(mentions[state.selectedIndex], at: index)
    }

    func executeMention(_ mention: BlockMentionItem, at index: Int) {
        mentionState = nil
        guard index >= 0, index < document.blocks.count else { return }

        let block = document.blocks[index]
        let content = block.content
        guard let openRange = content.range(of: "[[", options: .backwards) else { return }
        let before = String(content[content.startIndex..<openRange.lowerBound])
        let replacement = "[[" + mention.title + "]]"
        let newContent = before + replacement

        let blockId = block.id
        structuralEdit("Insert Mention", focus: BlockFocusRequest(blockId: blockId, cursorOffset: newContent.count)) { blocks in
            guard index < blocks.count else { return }
            blocks[index] = blocks[index].withContent(newContent, spans: [])
        }
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

    func handleEvent(_ event: BlockEditorEvent, on id: UUID) {
        guard let i = document.index(of: id) else { return }
        handleEvent(event, at: i)
    }

    func deleteBlock(id: UUID) {
        guard let i = document.index(of: id) else { return }
        deleteBlock(at: i)
    }

    func duplicateBlock(id: UUID) {
        guard let i = document.index(of: id) else { return }
        duplicateBlock(at: i)
    }

    func moveBlockUp(id: UUID) {
        guard let i = document.index(of: id) else { return }
        moveBlockUp(at: i)
    }

    func moveBlockDown(id: UUID) {
        guard let i = document.index(of: id) else { return }
        moveBlockDown(at: i)
    }

    func convertBlock(id: UUID, to kind: EditorBlockKind) {
        guard let i = document.index(of: id) else { return }
        convertBlock(at: i, to: kind)
    }

    func insertBlock(beforeId id: UUID) {
        guard let i = document.index(of: id) else { return }
        insertBlock(at: i)
    }

    func insertBlock(afterId id: UUID) {
        guard let i = document.index(of: id) else { return }
        insertBlock(at: i + 1)
    }

    func indentBlock(id: UUID) {
        guard let i = document.index(of: id) else { return }
        indentBlock(at: i)
    }

    func outdentBlock(id: UUID) {
        guard let i = document.index(of: id) else { return }
        outdentBlock(at: i)
    }

    func toggleCheckbox(id: UUID) {
        guard let i = document.index(of: id) else { return }
        toggleCheckbox(at: i)
    }

    func toggleCollapse(id: UUID) {
        guard let i = document.index(of: id) else { return }
        toggleCollapse(at: i)
    }

}
