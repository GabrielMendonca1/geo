import Foundation

struct MergeBlockCommand: EditorCommand {
    let name = "Merge Blocks"
    let blockIndex: Int
    let originalPrevBlock: EditorBlock
    let originalBlock: EditorBlock
    let mergedBlock: EditorBlock
    let cursorOffset: Int

    func execute(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        guard blockIndex > 0, blockIndex < blocks.count else { return nil }
        blocks[blockIndex - 1] = mergedBlock
        blocks.remove(at: blockIndex)
        return BlockFocusRequest(blockId: mergedBlock.id, cursorOffset: cursorOffset)
    }

    func undo(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        let prevIndex = blockIndex - 1
        guard prevIndex >= 0, prevIndex < blocks.count else { return nil }
        blocks[prevIndex] = originalPrevBlock
        blocks.insert(originalBlock, at: blockIndex)
        return BlockFocusRequest(blockId: originalBlock.id, cursorOffset: 0)
    }
}
