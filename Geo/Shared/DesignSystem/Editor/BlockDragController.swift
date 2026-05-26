import SwiftUI
import Observation

@Observable
final class BlockDragController {
    var draggedBlockId: UUID?
    var dropTargetIndex: Int?

    func draggedSubtreeIds(in blocks: [EditorBlock]) -> Set<UUID> {
        guard let dragId = draggedBlockId,
              let idx = blocks.firstIndex(where: { $0.id == dragId }) else { return [] }
        let range = BlockTreeNavigator.subtreeRange(of: idx, in: blocks)
        return Set(blocks[range].map(\.id))
    }

    func performDrop(blockId: UUID, toIndex: Int, in document: BlockEditorDocument, undoManager: UndoManager?) {
        guard let fromIndex = document.blocks.firstIndex(where: { $0.id == blockId }) else { return }
        let subtree = BlockTreeNavigator.subtreeRange(of: fromIndex, in: document.blocks)
        let adjustedIndex: Int
        if toIndex > fromIndex {
            adjustedIndex = max(0, toIndex - subtree.count)
        } else {
            adjustedIndex = toIndex
        }
        document.performStructuralEdit(undoManager: undoManager, name: "Reorder", newFocus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
            let slice = Array(blocks[subtree])
            blocks.removeSubrange(subtree)
            let safeIndex = min(max(0, adjustedIndex), blocks.count)
            blocks.insert(contentsOf: slice, at: safeIndex)
        }
        draggedBlockId = nil
        dropTargetIndex = nil
    }

    func makeDropDelegate(targetIndex: Int, moveBlock: @escaping (UUID, Int) -> Void) -> BlockDropDelegate {
        BlockDropDelegate(
            targetIndex: targetIndex,
            draggedBlockId: Binding(
                get: { self.draggedBlockId },
                set: { self.draggedBlockId = $0 }
            ),
            dropTargetIndex: Binding(
                get: { self.dropTargetIndex },
                set: { self.dropTargetIndex = $0 }
            ),
            moveBlock: moveBlock
        )
    }
}
