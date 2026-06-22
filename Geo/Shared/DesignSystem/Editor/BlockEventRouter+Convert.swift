import SwiftUI
import AppKit

extension BlockEventRouter {
    func convertBlock(at index: Int, to kind: EditorBlockKind) {
        guard index >= 0, index < document.blocks.count else { return }
        let block = document.blocks[index]
        if case .toggle(let expanded) = kind {
            let existingContent: String = {
                if case .toggle = block.kind { return block.toggleContent ?? "" }
                if case .callout = block.kind { return block.calloutContent ?? "" }
                return block.content
            }()
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                var toggle = EditorBlock.toggle(title: "", content: existingContent, expanded: expanded)
                toggle.id = block.id
                blocks[index] = toggle
            }
            return
        }
        if case .toggle = block.kind {
            let toggleTitle = block.toggleTitle ?? ""
            let toggleBody = block.toggleContent ?? ""
            if case .callout(let type, let incomingTitle) = kind {
                let finalTitle = incomingTitle ?? (toggleTitle.isEmpty ? nil : toggleTitle)
                let existingContent = toggleBody
                structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                    var callout = EditorBlock.callout(type: type, title: finalTitle, content: existingContent)
                    callout.id = block.id
                    blocks[index] = callout
                }
                return
            }
            let existingContent: String = {
                if toggleTitle.isEmpty { return toggleBody }
                if toggleBody.isEmpty { return toggleTitle }
                return toggleTitle + "\n" + toggleBody
            }()
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                let raw = existingContent + "\n"
                var newBlock = EditorBlock(
                    id: block.id, kind: kind,
                    sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                    rawText: raw, indent: "", prefix: "",
                    contentRange: NSRange(location: 0, length: (existingContent as NSString).length)
                )
                newBlock.cleanContent = existingContent
                if let prefixed = Self.convertedBlock(content: existingContent, kind: kind) {
                    var result = prefixed
                    result.id = block.id
                    blocks[index] = result
                } else {
                    blocks[index] = newBlock
                }
            }
            return
        }
        if case .callout(let type, let title) = kind {
            let existingContent: String = {
                if case .callout = block.kind { return block.calloutContent ?? "" }
                return block.content
            }()
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                var callout = EditorBlock.callout(type: type, title: title, content: existingContent)
                callout.id = block.id
                blocks[index] = callout
            }
            return
        }
        if case .callout = block.kind {
            let existingContent = block.calloutContent ?? ""
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                let raw = existingContent + "\n"
                var newBlock = EditorBlock(
                    id: block.id, kind: kind,
                    sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                    rawText: raw, indent: "", prefix: "",
                    contentRange: NSRange(location: 0, length: (existingContent as NSString).length)
                )
                newBlock.cleanContent = existingContent
                if let prefixed = Self.convertedBlock(content: existingContent, kind: kind) {
                    var result = prefixed
                    result.id = block.id
                    blocks[index] = result
                } else {
                    blocks[index] = newBlock
                }
            }
            return
        }
        if case .mathBlock = kind {
            let existingContent: String = {
                if case .mathBlock = block.kind { return block.mathContent ?? "" }
                return block.content
            }()
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                var math = EditorBlock.mathBlock(latex: existingContent)
                math.id = block.id
                blocks[index] = math
            }
            return
        }
        if case .mathBlock = block.kind {
            let existingContent = block.mathContent ?? ""
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                if let prefixed = Self.convertedBlock(content: existingContent, kind: kind) {
                    var result = prefixed
                    result.id = block.id
                    blocks[index] = result
                } else {
                    blocks[index] = EditorBlock.paragraph(content: existingContent)
                }
            }
            return
        }
        if case .codeBlock = block.kind {
            let existingContent = block.codeContent ?? ""
            structuralEdit("Turn Into", focus: BlockFocusRequest(blockId: block.id, cursorOffset: existingContent.count)) { blocks in
                if let prefixed = Self.convertedBlock(content: existingContent, kind: kind) {
                    var result = prefixed
                    result.id = block.id
                    blocks[index] = result
                } else {
                    var paragraph = EditorBlock.paragraph(content: existingContent)
                    paragraph.id = block.id
                    blocks[index] = paragraph
                }
            }
            return
        }
        document.executeCommand(ConvertBlockCommand(
            blockIndex: index,
            originalBlock: block,
            convertedBlock: block.withKind(kind)
        ), undoManager: undoManager)
    }

    private static func convertedBlock(content: String, kind: EditorBlockKind) -> EditorBlock? {
        switch kind {
        case .paragraph:
            return EditorBlock.paragraph(content: content)
        default:
            var block = EditorBlock.paragraph(content: content)
            let converted = block.withKind(kind)
            return converted
        }
    }
}
