import AppKit
import Observation

@Observable
final class BlockSelectionManager {
    var selectedBlockIds: Set<UUID> = []
    var selectionAnchorId: UUID?
    var dragAnchorIndex: Int?

    @ObservationIgnored
    private var blockSelectionMonitor: Any?

    func selectBlock(_ blockId: UUID) {
        selectedBlockIds = [blockId]
    }

    func toggleBlockSelection(_ blockId: UUID) {
        if selectedBlockIds.contains(blockId) {
            selectedBlockIds.remove(blockId)
        } else {
            selectedBlockIds.insert(blockId)
        }
    }

    func extendSelection(to index: Int, from anchorId: UUID, in blocks: [EditorBlock]) {
        guard let anchorIdx = blocks.firstIndex(where: { $0.id == anchorId }) else { return }
        let lo = min(anchorIdx, index)
        let hi = max(anchorIdx, index)
        selectedBlockIds = Set(blocks[lo...hi].map(\.id))
    }

    func selectAll(in blocks: [EditorBlock]) {
        selectedBlockIds = Set(blocks.map(\.id))
    }

    func clearSelection() {
        selectedBlockIds.removeAll()
    }

    func moveSelectionUp(in blocks: [EditorBlock], focusCoordinator: EditorFocusCoordinator) {
        let firstSelectedId = blocks.first(where: { selectedBlockIds.contains($0.id) })?.id
        guard let currentId = firstSelectedId ?? focusCoordinator.activeFocusedBlockId,
              let currentIdx = blocks.firstIndex(where: { $0.id == currentId }) else { return }
        var i = currentIdx - 1
        while i >= 0 {
            if !Self.isNonEditable(blocks[i].kind) {
                let newId = blocks[i].id
                selectedBlockIds = [newId]
                focusCoordinator.activeFocusedBlockId = newId
                return
            }
            i -= 1
        }
    }

    func moveSelectionDown(in blocks: [EditorBlock], focusCoordinator: EditorFocusCoordinator) {
        let lastSelectedId = blocks.last(where: { selectedBlockIds.contains($0.id) })?.id
        guard let currentId = lastSelectedId ?? focusCoordinator.activeFocusedBlockId,
              let currentIdx = blocks.firstIndex(where: { $0.id == currentId }) else { return }
        var i = currentIdx + 1
        while i < blocks.count {
            if !Self.isNonEditable(blocks[i].kind) {
                let newId = blocks[i].id
                selectedBlockIds = [newId]
                focusCoordinator.activeFocusedBlockId = newId
                return
            }
            i += 1
        }
    }

    func enterSelectedBlock(in blocks: [EditorBlock], focusCoordinator: EditorFocusCoordinator, document: BlockEditorDocument) {
        let blockId = blocks.first(where: { selectedBlockIds.contains($0.id) })?.id
            ?? focusCoordinator.activeFocusedBlockId
        guard let blockId else { return }
        selectedBlockIds.removeAll()
        document.focusRequest = BlockFocusRequest(blockId: blockId, cursorOffset: 0)
    }

    func deleteSelectedBlocks(from document: BlockEditorDocument, undoManager: UndoManager?) {
        guard selectedBlockIds.count > 0 else { return }
        let ids = selectedBlockIds
        let firstDeletedIdx = document.blocks.firstIndex { ids.contains($0.id) } ?? 0
        selectedBlockIds.removeAll()
        document.performStructuralEdit(undoManager: undoManager, name: "Delete Blocks", newFocus: nil) { blocks in
            blocks.removeAll { ids.contains($0.id) }
            if blocks.isEmpty {
                blocks = [EditorBlock.empty()]
            }
        }
        let safeIdx = min(firstDeletedIdx, document.blocks.count - 1)
        let targetId = document.blocks[safeIdx].id
        document.focusRequest = BlockFocusRequest(blockId: targetId, cursorOffset: 0)
    }

    func duplicateSelectedBlocks(in document: BlockEditorDocument, undoManager: UndoManager?) {
        guard !selectedBlockIds.isEmpty else { return }
        let ids = selectedBlockIds
        var firstCopyId: UUID?
        var copyIds: Set<UUID> = []
        document.performStructuralEdit(undoManager: undoManager, name: "Duplicate Blocks", newFocus: nil) { blocks in
            let selectedIndices = blocks.enumerated()
                .filter { ids.contains($0.element.id) }
                .map(\.offset)
            guard let lastIdx = selectedIndices.last else { return }
            var copies: [EditorBlock] = []
            for idx in selectedIndices {
                var copy = blocks[idx]
                copy.id = UUID()
                copies.append(copy)
            }
            firstCopyId = copies.first?.id
            copyIds = Set(copies.map(\.id))
            blocks.insert(contentsOf: copies, at: min(lastIdx + 1, blocks.count))
        }
        selectedBlockIds = copyIds
        if let fid = firstCopyId {
            document.focusRequest = BlockFocusRequest(blockId: fid, cursorOffset: 0)
        }
    }

    func copySelectedBlocks(from document: BlockEditorDocument) {
        let selectedContent = document.blocks
            .filter { selectedBlockIds.contains($0.id) }
            .map(\.rawText)
            .joined()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedContent, forType: .string)
    }

    func cutSelectedBlocks(from document: BlockEditorDocument, undoManager: UndoManager?) {
        copySelectedBlocks(from: document)
        deleteSelectedBlocks(from: document, undoManager: undoManager)
    }

    func selectBlockUp(from index: Int, in blocks: [EditorBlock]) {
        guard index > 0 else { return }
        let currentId = blocks[index].id
        if selectedBlockIds.isEmpty {
            selectedBlockIds = [currentId]
        }
        var i = index - 1
        while i >= 0 {
            if !Self.isNonEditable(blocks[i].kind) {
                selectedBlockIds.insert(blocks[i].id)
                selectedBlockIds.insert(currentId)
                break
            }
            selectedBlockIds.insert(blocks[i].id)
            i -= 1
        }
    }

    func selectBlockDown(from index: Int, in blocks: [EditorBlock]) {
        guard index < blocks.count - 1 else { return }
        let currentId = blocks[index].id
        if selectedBlockIds.isEmpty {
            selectedBlockIds = [currentId]
        }
        var i = index + 1
        while i < blocks.count {
            if !Self.isNonEditable(blocks[i].kind) {
                selectedBlockIds.insert(blocks[i].id)
                selectedBlockIds.insert(currentId)
                break
            }
            selectedBlockIds.insert(blocks[i].id)
            i += 1
        }
    }

    func handleBlockHandleClick(at index: Int, blockId: UUID, in blocks: [EditorBlock], focusCoordinator: EditorFocusCoordinator) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchorId = focusCoordinator.activeFocusedBlockId ?? selectedBlockIds.first {
            guard let anchorIdx = blocks.firstIndex(where: { $0.id == anchorId }) else { return }
            let lo = min(anchorIdx, index)
            let hi = max(anchorIdx, index)
            selectedBlockIds = Set(blocks[lo...hi].map(\.id))
        } else if flags.contains(.command) {
            toggleBlockSelection(blockId)
        } else {
            selectedBlockIds = [blockId]
        }
        focusCoordinator.activeFocusedBlockId = blockId
    }

    func handleDragOutside(_ windowPoint: NSPoint, fromIndex anchorIndex: Int, in blocks: [EditorBlock], focusCoordinator: EditorFocusCoordinator) {
        guard let window = NSApp.keyWindow else { return }
        let hitIdx = blockIndexAtPoint(windowPoint, in: window, blocks: blocks, focusCoordinator: focusCoordinator)
        guard let hit = hitIdx, hit != anchorIndex else { return }
        if selectedBlockIds.isEmpty {
            dragAnchorIndex = anchorIndex
            installSelectionMonitor(active: true, blocks: { blocks }, focusCoordinator: focusCoordinator, document: nil, undoManager: nil)
        }
        let lo = min(anchorIndex, hit)
        let hi = max(anchorIndex, hit)
        selectedBlockIds = Set(blocks[lo...hi].map(\.id))
    }

    func installSelectionMonitor(active: Bool, blocks: @escaping () -> [EditorBlock], focusCoordinator: EditorFocusCoordinator, document: BlockEditorDocument?, undoManager: UndoManager?) {
        if let existing = blockSelectionMonitor {
            NSEvent.removeMonitor(existing)
            blockSelectionMonitor = nil
        }
        guard active else { return }
        blockSelectionMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.selectedBlockIds.isEmpty else { return event }
            let currentBlocks = blocks()
            switch event.keyCode {
            case 126:
                self.moveSelectionUp(in: currentBlocks, focusCoordinator: focusCoordinator)
                return nil
            case 125:
                self.moveSelectionDown(in: currentBlocks, focusCoordinator: focusCoordinator)
                return nil
            case 36:
                if let document {
                    self.enterSelectedBlock(in: currentBlocks, focusCoordinator: focusCoordinator, document: document)
                }
                return nil
            case 51, 117:
                if let document {
                    self.deleteSelectedBlocks(from: document, undoManager: undoManager)
                }
                return nil
            case 53:
                self.selectedBlockIds.removeAll()
                focusCoordinator.activeFocusedBlockId = nil
                return nil
            default:
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags == .command, let chars = event.charactersIgnoringModifiers {
                    switch chars {
                    case "a":
                        self.selectAll(in: currentBlocks)
                        return nil
                    case "c":
                        if let document {
                            self.copySelectedBlocks(from: document)
                        }
                        return nil
                    case "x":
                        if let document {
                            self.cutSelectedBlocks(from: document, undoManager: undoManager)
                        }
                        return nil
                    default:
                        break
                    }
                }
                return event
            }
        }
    }

    func teardownMonitor() {
        if let existing = blockSelectionMonitor {
            NSEvent.removeMonitor(existing)
            blockSelectionMonitor = nil
        }
    }

    private func blockIndexAtPoint(_ windowPoint: NSPoint, in window: NSWindow, blocks: [EditorBlock], focusCoordinator: EditorFocusCoordinator) -> Int? {
        var hitIndex: Int?
        var closestDist: CGFloat = .greatestFiniteMagnitude
        for (index, block) in blocks.enumerated() {
            guard let tv = focusCoordinator.textView(for: block.id) else { continue }
            guard let tvWindow = tv.window, tvWindow == window else { continue }
            let localPoint = tv.convert(windowPoint, from: nil)
            if localPoint.y >= 0 && localPoint.y <= tv.bounds.height {
                return index
            }
            let midY = tv.bounds.height / 2
            let dist = abs(localPoint.y - midY)
            if dist < closestDist {
                closestDist = dist
                hitIndex = index
            }
        }
        return hitIndex
    }

    static func isNonEditable(_ kind: EditorBlockKind) -> Bool {
        switch kind {
        case .horizontalRule, .image:
            return true
        default:
            return false
        }
    }
}
