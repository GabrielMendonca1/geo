import SwiftUI

struct MentionOverlay: View {
    let items: [BlockMentionItem]
    let selectedIndex: Int
    let onSelect: (BlockMentionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { i, item in
                Button {
                    onSelect(item)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").frame(width: 18)
                            .foregroundColor(i == selectedIndex ? Color(Palette.editorForeground) : Palette.tertiaryForeground)
                        Text(item.title.isEmpty ? "Untitled" : item.title)
                            .foregroundColor(Color(Palette.editorForeground))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(i == selectedIndex ? Palette.accent.opacity(0.12) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Palette.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .frame(width: 260).zIndex(100)
    }

    static func filtered(mentionState: MentionState?, mentionableBlocks: [BlockMentionItem]) -> [BlockMentionItem] {
        guard let state = mentionState else { return [] }
        if state.filter.isEmpty { return Array(mentionableBlocks.prefix(8)) }
        let query = state.filter.lowercased()
        return Array(mentionableBlocks.filter { $0.title.lowercased().contains(query) }.prefix(8))
    }
}
