import Foundation

struct MoveBlockCommand: EditorCommand {
    let name = "Move Block"
    let snapshotBefore: [EditorBlock]
    let snapshotAfter: [EditorBlock]
    let focusBlockId: UUID

    func execute(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        blocks = snapshotAfter
        return BlockFocusRequest(blockId: focusBlockId, cursorOffset: 0)
    }

    func undo(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        blocks = snapshotBefore
        return BlockFocusRequest(blockId: focusBlockId, cursorOffset: 0)
    }
}
