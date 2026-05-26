import Foundation

struct IndentBlockCommand: EditorCommand {
    let name = "Indent"
    let blockIndex: Int
    let subtreeCount: Int
    let oldIndents: [String]
    let newIndents: [String]

    func execute(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        for i in 0..<subtreeCount {
            let idx = blockIndex + i
            guard idx < blocks.count else { break }
            blocks[idx] = blocks[idx].withIndent(newIndents[i])
        }
        return nil
    }

    func undo(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        for i in 0..<subtreeCount {
            let idx = blockIndex + i
            guard idx < blocks.count else { break }
            blocks[idx] = blocks[idx].withIndent(oldIndents[i])
        }
        return nil
    }
}
