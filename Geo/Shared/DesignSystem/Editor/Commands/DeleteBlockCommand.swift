import Foundation

struct DeleteBlockCommand: EditorCommand {
    let name = "Delete Block"
    let blockIndex: Int
    let deletedBlocks: [EditorBlock]
    let focusRequest: BlockFocusRequest?

    func execute(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        let end = min(blockIndex + deletedBlocks.count, blocks.count)
        guard blockIndex >= 0, blockIndex < blocks.count, end <= blocks.count else { return nil }
        blocks.removeSubrange(blockIndex..<end)
        if blocks.isEmpty {
            blocks = [EditorBlock.empty()]
        }
        return focusRequest
    }

    func undo(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        if blocks.count == 1, case .empty = blocks[0].kind {
            blocks.removeAll()
        }
        let insertAt = min(blockIndex, blocks.count)
        blocks.insert(contentsOf: deletedBlocks, at: insertAt)
        return BlockFocusRequest(blockId: deletedBlocks[0].id, cursorOffset: 0)
    }
}
