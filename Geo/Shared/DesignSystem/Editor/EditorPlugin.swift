import Foundation

struct PluginContext {
    let blocks: [EditorBlock]
    let selection: EditorSelection
    let focusedBlockId: UUID?
}

protocol EditorPlugin: AnyObject {
    var name: String { get }
    func onTransaction(_ transaction: EditorTransaction, oldContext: PluginContext, newContext: PluginContext)
}

private func isSlashEligible(_ kind: EditorBlockKind) -> Bool {
    switch kind {
    case .paragraph, .heading, .bulletItem, .orderedItem, .checkboxItem, .blockquote, .empty:
        return true
    default:
        return false
    }
}

private func cursorOffset(in selection: EditorSelection, for blockId: UUID) -> Int? {
    switch selection {
    case .caret(let id, let off) where id == blockId:
        return off
    case .range(let id, let r) where id == blockId:
        return r.location + r.length
    default:
        return nil
    }
}

final class SlashMenuPlugin: EditorPlugin {
    let name = "SlashMenu"
    weak var router: BlockEventRouter?

    func onTransaction(_ transaction: EditorTransaction, oldContext: PluginContext, newContext: PluginContext) {
        guard let router else { return }
        if (transaction.meta["composing"] as? Bool) == true { return }

        guard let focusedId = newContext.focusedBlockId,
              let index = newContext.blocks.firstIndex(where: { $0.id == focusedId })
        else {
            router.slashState = nil
            return
        }

        let block = newContext.blocks[index]
        guard isSlashEligible(block.kind) else {
            router.slashState = nil
            return
        }

        let content = block.content
        let metaCaret = transaction.meta["postEditCaret"] as? Int
        let caret = metaCaret ?? cursorOffset(in: newContext.selection, for: focusedId) ?? content.count
        let ns = content as NSString
        let clamped = max(0, min(caret, ns.length))
        let upToCaret = ns.substring(to: clamped)

        guard upToCaret.hasPrefix("/") else {
            router.slashState = nil
            return
        }

        let filter = String(upToCaret.dropFirst())
        if filter.contains(" ") || filter.contains("\n") {
            router.slashState = nil
            return
        }

        if var existing = router.slashState, existing.blockId == focusedId {
            existing.filter = filter
            existing.selectedIndex = 0
            router.slashState = existing
        } else {
            router.slashState = SlashState(blockId: focusedId, blockIndex: index, filter: filter, selectedIndex: 0)
        }
    }
}

final class MentionMenuPlugin: EditorPlugin {
    let name = "MentionMenu"
    weak var router: BlockEventRouter?

    func onTransaction(_ transaction: EditorTransaction, oldContext: PluginContext, newContext: PluginContext) {
        guard let router else { return }
        if (transaction.meta["composing"] as? Bool) == true { return }

        guard let focusedId = newContext.focusedBlockId,
              let index = newContext.blocks.firstIndex(where: { $0.id == focusedId })
        else {
            router.mentionState = nil
            return
        }

        let block = newContext.blocks[index]
        let content = block.content
        let metaCaret = transaction.meta["postEditCaret"] as? Int
        let caret = metaCaret ?? cursorOffset(in: newContext.selection, for: focusedId) ?? content.count
        let ns = content as NSString
        let clamped = max(0, min(caret, ns.length))
        let upToCaret = ns.substring(to: clamped)

        guard let openRange = upToCaret.range(of: "[[", options: .backwards) else {
            router.mentionState = nil
            return
        }

        let after = upToCaret[openRange.upperBound..<upToCaret.endIndex]
        if after.contains("]]") || after.contains("\n") {
            router.mentionState = nil
            return
        }

        let filter = String(after)
        if var existing = router.mentionState, existing.blockId == focusedId {
            existing.filter = filter
            existing.selectedIndex = 0
            router.mentionState = existing
        } else {
            router.mentionState = MentionState(blockId: focusedId, blockIndex: index, filter: filter, selectedIndex: 0)
        }
    }
}
