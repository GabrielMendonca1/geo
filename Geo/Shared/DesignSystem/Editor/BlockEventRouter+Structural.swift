import SwiftUI
import AppKit
import os.log

private let pasteLinesLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "BlockEventRouter")

extension BlockEventRouter {
    static let pasteLineCap = 500

    func splitBlock(at index: Int, cursorOffset: Int, newBlockContent: String, spans: [InlineSpan]) {
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

    func mergeWithPrevious(at index: Int, content: String, spans: [InlineSpan]) {
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

    func moveToPreviousBlock(from index: Int, cursorHint: Int) {
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

    func moveToNextBlock(from index: Int, cursorHint: Int) {
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
        structuralEdit("Move Block", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
            blocks = afterBlocks
        }
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
        structuralEdit("Move Block", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
            blocks = afterBlocks
        }
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

    func indentBlock(at index: Int) {
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

    func outdentBlock(at index: Int) {
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

    func pasteLines(at index: Int, lines: [String]) {
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
}
