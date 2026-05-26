import Foundation

struct SplitBlockCommand: EditorCommand {
    let name = "Split Block"
    let blockIndex: Int
    let originalBlock: EditorBlock
    let updatedBlock: EditorBlock
    let newBlock: EditorBlock

    func execute(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        guard blockIndex >= 0, blockIndex < blocks.count else { return nil }
        blocks[blockIndex] = updatedBlock
        blocks.insert(newBlock, at: min(blockIndex + 1, blocks.count))
        return BlockFocusRequest(blockId: newBlock.id, cursorOffset: 0)
    }

    func undo(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        guard blockIndex >= 0, blockIndex < blocks.count else { return nil }
        blocks[blockIndex] = originalBlock
        let removeIndex = blockIndex + 1
        if removeIndex < blocks.count {
            blocks.remove(at: removeIndex)
        }
        return BlockFocusRequest(blockId: originalBlock.id, cursorOffset: originalBlock.content.count)
    }
}
