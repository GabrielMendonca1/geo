import SwiftUI
import AppKit

extension BlockEventRouter {
    func handleContentChange(content: String, spans: [InlineSpan], at index: Int) {
        selectionManager.clearSelection()
        if case .table = document.blocks[index].kind {
            let blockId = document.blocks[index].id
            structuralEdit("Edit Table", focus: nil) { blocks in
                guard index < blocks.count else { return }
                let raw = content
                blocks[index] = EditorBlock(
                    id: blockId, kind: .table,
                    sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                    rawText: raw, indent: "", prefix: "",
                    contentRange: NSRange(location: 0, length: (raw as NSString).length)
                )
            }
            return
        }
        if case .callout = document.blocks[index].kind {
            let block = document.blocks[index]
            let updated = block.withCalloutContent(content)
            structuralEdit("Edit Callout", focus: nil) { blocks in
                guard index < blocks.count else { return }
                blocks[index] = updated
            }
            return
        }
        if case .toggle = document.blocks[index].kind {
            let block = document.blocks[index]
            let updated = block.withToggleContent(content)
            structuralEdit("Edit Toggle", focus: nil) { blocks in
                guard index < blocks.count else { return }
                blocks[index] = updated
            }
            return
        }
        if case .mathBlock = document.blocks[index].kind {
            let block = document.blocks[index]
            let updated = block.withMathContent(content)
            structuralEdit("Edit Math Block", focus: nil) { blocks in
                guard index < blocks.count else { return }
                blocks[index] = updated
            }
            return
        }
        document.updateBlockContent(at: index, content: content, spans: spans)
        guard index < document.blocks.count else { return }
        if case .paragraph = document.blocks[index].kind {
            if content.contains("\n") {
                var lines = content.components(separatedBy: "\n")
                while lines.last?.isEmpty == true && lines.count > 1 { lines.removeLast() }
                if lines.count > 1 {
                    pasteLines(at: index, lines: lines)
                    return
                }
            }
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if MarkdownBlockParser.isHorizontalRule(trimmed) {
                let blockId = document.blocks[index].id
                let newBlock = EditorBlock.paragraph(content: "")
                structuralEdit("Horizontal Rule", focus: BlockFocusRequest(blockId: newBlock.id, cursorOffset: 0)) { blocks in
                    guard index < blocks.count else { return }
                    var divider = EditorBlock.divider()
                    divider.id = blockId
                    blocks[index] = divider
                    blocks.insert(newBlock, at: index + 1)
                }
            } else if let img = MarkdownBlockParser.parseImageMarkdown(content) {
                let blockId = document.blocks[index].id
                let newBlock = EditorBlock.paragraph(content: "")
                structuralEdit("Insert Image", focus: BlockFocusRequest(blockId: newBlock.id, cursorOffset: 0)) { blocks in
                    guard index < blocks.count else { return }
                    let raw = "![\(img.alt)](\(img.url))\n"
                    blocks[index] = EditorBlock(
                        id: blockId, kind: .image(alt: img.alt, url: img.url),
                        sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                        rawText: raw, indent: "", prefix: "",
                        contentRange: NSRange(location: 0, length: (raw as NSString).length - 1)
                    )
                    blocks.insert(newBlock, at: index + 1)
                }
            } else if let outcome = BlockPrefixDetector.detect(content) {
                let blockId = document.blocks[index].id
                slashState = nil
                mentionState = nil
                switch outcome {
                case .convert(let kind, let remainingContent):
                    structuralEdit("Auto Format", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                        guard index < blocks.count else { return }
                        blocks[index] = blocks[index]
                            .withContent(remainingContent, spans: [])
                            .withKind(kind)
                    }
                case .insertCodeBlock:
                    let raw = "```\n\n```\n"
                    let codeBlock = EditorBlock(
                        id: blockId, kind: .codeBlock(language: nil),
                        sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                        rawText: raw, indent: "", prefix: "",
                        contentRange: NSRange(location: 4, length: 0)
                    )
                    structuralEdit("Auto Format Code Block", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                        guard index < blocks.count else { return }
                        blocks[index] = codeBlock
                    }
                case .insertMathBlock:
                    var mathBlock = EditorBlock.mathBlock()
                    mathBlock.id = blockId
                    structuralEdit("Auto Format Math Block", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                        guard index < blocks.count else { return }
                        blocks[index] = mathBlock
                    }
                }
            }
        }
    }
}
