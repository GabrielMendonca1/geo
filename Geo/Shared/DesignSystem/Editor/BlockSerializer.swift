import Foundation

enum BlockSerializer {

    static func serialize(_ document: BlockDocument) -> String {
        document.blocks.map(\.rawText).joined()
    }
}
