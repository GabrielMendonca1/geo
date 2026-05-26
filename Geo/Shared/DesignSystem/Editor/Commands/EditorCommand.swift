import Foundation

protocol EditorCommand {
    var name: String { get }
    func execute(on blocks: inout [EditorBlock]) -> BlockFocusRequest?
    func undo(on blocks: inout [EditorBlock]) -> BlockFocusRequest?
}
