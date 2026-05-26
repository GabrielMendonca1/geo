import SwiftUI

enum EditorOverlayZ {
    static let dragHandle: Double = 10
    static let formatToolbar: Double = 20
    static let mentionMenu: Double = 25
    static let slashMenu: Double = 30
}

struct BlockRowBoundsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct EditorOverlayLayer: View {
    let router: BlockEventRouter
    let rowBounds: [UUID: CGRect]
    let mentionableBlocks: [BlockMentionItem]
    let onSlashSelect: (BlockSlashCommand, Int) -> Void
    let onMentionSelect: (BlockMentionItem, Int) -> Void

    private static let menuVerticalGap: CGFloat = 4
    private static let slashMenuWidth: CGFloat = 280
    private static let mentionMenuWidth: CGFloat = 260

    var body: some View {
        ZStack(alignment: .topLeading) {
            slashLayer
            mentionLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var slashLayer: some View {
        if let state = router.slashState, let rect = rowBounds[state.blockId] {
            let commands = SlashCommandOverlay.filtered(for: state.blockId, slashState: state)
            if !commands.isEmpty {
                SlashCommandOverlay(
                    commands: commands,
                    selectedIndex: state.selectedIndex,
                    onSelect: { cmd in onSlashSelect(cmd, state.blockIndex) }
                )
                .frame(width: Self.slashMenuWidth)
                .fixedSize(horizontal: true, vertical: true)
                .offset(
                    x: rect.minX,
                    y: rect.maxY + Self.menuVerticalGap
                )
                .allowsHitTesting(true)
                .zIndex(EditorOverlayZ.slashMenu)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var mentionLayer: some View {
        if let state = router.mentionState, let rect = rowBounds[state.blockId] {
            let items = MentionOverlay.filtered(mentionState: state, mentionableBlocks: mentionableBlocks)
            if !items.isEmpty {
                MentionOverlay(
                    items: items,
                    selectedIndex: state.selectedIndex,
                    onSelect: { item in onMentionSelect(item, state.blockIndex) }
                )
                .frame(width: Self.mentionMenuWidth)
                .fixedSize(horizontal: true, vertical: true)
                .offset(
                    x: rect.minX,
                    y: rect.maxY + Self.menuVerticalGap
                )
                .allowsHitTesting(true)
                .zIndex(EditorOverlayZ.mentionMenu)
                .transition(.opacity)
            }
        }
    }
}

extension SlashCommandOverlay {
    static func filtered(for blockId: UUID, slashState: SlashState) -> [BlockSlashCommand] {
        filtered(for: blockId, slashState: Optional(slashState))
    }
}

extension MentionOverlay {
    static func filtered(mentionState: MentionState, mentionableBlocks: [BlockMentionItem]) -> [BlockMentionItem] {
        filtered(mentionState: Optional(mentionState), mentionableBlocks: mentionableBlocks)
    }
}
