import AppKit
import os

struct BlockFocusRequest: Equatable {
    let blockId: UUID
    let cursorOffset: Int
    let generation: UInt64

    init(blockId: UUID, cursorOffset: Int) {
        self.blockId = blockId
        self.cursorOffset = cursorOffset
        self.generation = Self.nextGeneration()
    }

    private static let counterLock = OSAllocatedUnfairLock(initialState: UInt64(0))
    private static func nextGeneration() -> UInt64 {
        counterLock.withLock { state in
            state &+= 1
            return state
        }
    }
}

enum BlockEditorEvent {
    case contentChange(String, [InlineSpan])
    case focus
    case split(cursorOffset: Int, after: String, spans: [InlineSpan])
    case delete
    case merge(String, [InlineSpan])
    case pasteLines([String])
    case arrowUp(Int)
    case arrowDown(Int)
    case moveUp
    case moveDown
    case duplicate
    case indent
    case outdent
    case slashNavigateUp
    case slashNavigateDown
    case slashSelect
    case slashDismissed
    case mentionNavigateUp
    case mentionNavigateDown
    case mentionSelect
    case mentionDismissed
    case escapeBlock
    case convertTo(EditorBlockKind)
    case selectUp
    case selectDown
    case dragSelectUp
    case dragSelectDown
    case wikiLinkClicked(WikiLinkClickPayload)
    case findRequested
    case selectAllBlocks
    case transaction(EditorTransaction)
}

struct WikiLinkClickPayload: Equatable {
    let target: String
    let anchor: String?
    let isEmbed: Bool
}

struct ActiveFormattingState {
    var isBold: Bool = false
    var isItalic: Bool = false
    var isStrikethrough: Bool = false
    var isCode: Bool = false
    var isHighlight: Bool = false
}
