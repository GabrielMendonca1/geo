import Foundation

struct ConvertBlockCommand: EditorCommand {
    let name = "Turn Into"
    let blockIndex: Int
    let originalBlock: EditorBlock
    let convertedBlock: EditorBlock

    func execute(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        guard blockIndex >= 0, blockIndex < blocks.count else { return nil }
        blocks[blockIndex] = convertedBlock
        return BlockFocusRequest(blockId: convertedBlock.id, cursorOffset: convertedBlock.content.count)
    }

    func undo(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        guard blockIndex >= 0, blockIndex < blocks.count else { return nil }
        blocks[blockIndex] = originalBlock
        return BlockFocusRequest(blockId: originalBlock.id, cursorOffset: originalBlock.content.count)
    }
}
