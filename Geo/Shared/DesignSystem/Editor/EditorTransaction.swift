import Foundation

protocol EditorStep {
    var name: String { get }
    func apply(_ blocks: inout [EditorBlock], selection: inout EditorSelection) -> EditorStep?
}

struct ReplaceContentStep: EditorStep {
    let blockId: UUID
    let content: String
    let spans: [InlineSpan]

    var name: String { "Replace Content" }

    func apply(_ blocks: inout [EditorBlock], selection: inout EditorSelection) -> EditorStep? {
        guard let index = blocks.firstIndex(where: { $0.id == blockId }) else { return nil }
        let current = blocks[index]
        let prevContent: String
        let prevSpans = current.spans
        let updated: EditorBlock
        switch current.kind {
        case .codeBlock:
            prevContent = current.codeContent ?? ""
            updated = current.withCodeContent(content)
        case .mathBlock:
            prevContent = current.mathContent ?? ""
            updated = current.withMathContent(content)
        case .callout:
            prevContent = current.calloutContent ?? ""
            updated = current.withCalloutContent(content)
        case .toggle:
            prevContent = current.toggleContent ?? ""
            updated = current.withToggleContent(content)
        default:
            prevContent = current.content
            updated = current.withContent(content, spans: spans)
        }
        blocks[index] = updated
        return ReplaceContentStep(blockId: blockId, content: prevContent, spans: prevSpans)
    }
}

struct InsertBlocksStep: EditorStep {
    let at: Int
    let blocks: [EditorBlock]

    var name: String { "Insert Blocks" }

    func apply(_ blocks: inout [EditorBlock], selection: inout EditorSelection) -> EditorStep? {
        let insertAt = max(0, min(at, blocks.count))
        blocks.insert(contentsOf: self.blocks, at: insertAt)
        return nil
    }
}

struct SetSelectionStep: EditorStep {
    let newSelection: EditorSelection

    var name: String { "Set Selection" }

    func apply(_ blocks: inout [EditorBlock], selection: inout EditorSelection) -> EditorStep? {
        let previous = selection
        selection = newSelection
        return SetSelectionStep(newSelection: previous)
    }
}

struct TransactionMeta {
    var postEditCaret: Int?
    var composing: Bool
}

struct EditorTransaction {
    let name: String
    var steps: [EditorStep]
    var meta: TransactionMeta

    init(name: String, steps: [EditorStep], meta: TransactionMeta = TransactionMeta(postEditCaret: nil, composing: false)) {
        self.name = name
        self.steps = steps
        self.meta = meta
    }

    static func replaceContent(blockId: UUID, content: String, spans: [InlineSpan] = []) -> EditorTransaction {
        EditorTransaction(
            name: "Replace Content",
            steps: [ReplaceContentStep(blockId: blockId, content: content, spans: spans)]
        )
    }
}
