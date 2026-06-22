import SwiftUI
import AppKit

extension BlockEventRouter {
    func navigateSlashUp() {
        guard var state = slashState else { return }
        let count = SlashCommandOverlay.filtered(for: state.blockId, slashState: state).count
        if count > 0 {
            state.selectedIndex = (state.selectedIndex - 1 + count) % count
            slashState = state
        }
    }

    func navigateSlashDown() {
        guard var state = slashState else { return }
        let count = SlashCommandOverlay.filtered(for: state.blockId, slashState: state).count
        if count > 0 {
            state.selectedIndex = (state.selectedIndex + 1) % count
            slashState = state
        }
    }

    func selectSlashCommand(at index: Int) {
        guard let state = slashState else { return }
        let commands = SlashCommandOverlay.filtered(for: state.blockId, slashState: slashState)
        guard state.selectedIndex < commands.count else { return }
        executeBlockSlashCommand(commands[state.selectedIndex], at: index)
    }

    func executeBlockSlashCommand(_ command: BlockSlashCommand, at index: Int) {
        slashState = nil
        guard index >= 0, index < document.blocks.count else { return }

        switch command.action {
        case .convertTo(let kind):
            let blockId = document.blocks[index].id
            structuralEdit("Slash Command", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                blocks[index] = blocks[index].withContent("").withKind(kind)
            }
        case .insertDivider:
            let blockId = document.blocks[index].id
            let newBlock = EditorBlock.paragraph(content: "")
            structuralEdit("Insert Divider", focus: BlockFocusRequest(blockId: newBlock.id, cursorOffset: 0)) { blocks in
                var divider = EditorBlock.divider()
                divider.id = blockId
                blocks[index] = divider
                blocks.insert(newBlock, at: index + 1)
            }
        case .insertCallout(let calloutType):
            let blockId = document.blocks[index].id
            structuralEdit("Insert Callout", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                var callout = EditorBlock.callout(type: calloutType)
                callout.id = blockId
                blocks[index] = callout
            }
        case .insertToggle:
            let blockId = document.blocks[index].id
            structuralEdit("Insert Toggle", focus: BlockFocusRequest(blockId: blockId, cursorOffset: 0)) { blocks in
                var toggle = EditorBlock.toggle(expanded: true)
                toggle.id = blockId
                blocks[index] = toggle
            }
        case .insertTemplate:
            structuralEdit("Clear Slash", focus: BlockFocusRequest(blockId: document.blocks[index].id, cursorOffset: 0)) { blocks in
                blocks[index] = blocks[index].withContent("")
            }
            templatePickerRequested = true
        case .insertTable:
            let blockId = document.blocks[index].id
            let tableMarkdown = TableModel.defaultTable().serialize()
            let newBlock = EditorBlock.paragraph(content: "")
            structuralEdit("Insert Table", focus: nil) { blocks in
                let raw = tableMarkdown
                blocks[index] = EditorBlock(
                    id: blockId, kind: .table,
                    sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                    rawText: raw, indent: "", prefix: "",
                    contentRange: NSRange(location: 0, length: (raw as NSString).length)
                )
                blocks.insert(newBlock, at: index + 1)
            }
        case .insertMathBlock:
            let mathBlock = EditorBlock.mathBlock()
            structuralEdit("Insert Math Block", focus: BlockFocusRequest(blockId: mathBlock.id, cursorOffset: 0)) { blocks in
                blocks[index] = mathBlock
            }
        case .insertCodeBlock:
            let raw = "```\n\n```\n"
            let codeBlock = EditorBlock(
                id: UUID(), kind: .codeBlock(language: nil),
                sourceRange: NSRange(location: 0, length: (raw as NSString).length),
                rawText: raw, indent: "", prefix: "",
                contentRange: NSRange(location: 4, length: 0)
            )
            structuralEdit("Insert Code Block", focus: BlockFocusRequest(blockId: codeBlock.id, cursorOffset: 0)) { blocks in
                blocks[index] = codeBlock
            }
        }
    }

    func navigateMentionUp() {
        guard var state = mentionState else { return }
        let count = MentionOverlay.filtered(mentionState: state, mentionableBlocks: mentionableBlocks).count
        if count > 0 {
            state.selectedIndex = (state.selectedIndex - 1 + count) % count
            mentionState = state
        }
    }

    func navigateMentionDown() {
        guard var state = mentionState else { return }
        let count = MentionOverlay.filtered(mentionState: state, mentionableBlocks: mentionableBlocks).count
        if count > 0 {
            state.selectedIndex = (state.selectedIndex + 1) % count
            mentionState = state
        }
    }

    func selectMention(at index: Int) {
        guard let state = mentionState else { return }
        let mentions = MentionOverlay.filtered(mentionState: mentionState, mentionableBlocks: mentionableBlocks)
        guard state.selectedIndex < mentions.count else { return }
        executeMention(mentions[state.selectedIndex], at: index)
    }

    func executeMention(_ mention: BlockMentionItem, at index: Int) {
        mentionState = nil
        guard index >= 0, index < document.blocks.count else { return }

        let block = document.blocks[index]
        let content = block.content
        guard let openRange = content.range(of: "[[", options: .backwards) else { return }
        let before = String(content[content.startIndex..<openRange.lowerBound])
        let replacement = "[[" + mention.title + "]]"
        let newContent = before + replacement

        let blockId = block.id
        structuralEdit("Insert Mention", focus: BlockFocusRequest(blockId: blockId, cursorOffset: newContent.count)) { blocks in
            guard index < blocks.count else { return }
            blocks[index] = blocks[index].withContent(newContent, spans: [])
        }
    }
}
