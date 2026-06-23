import SwiftUI

struct MentionOverlay: View {
    let items: [BlockMentionItem]
    let selectedIndex: Int
    let onSelect: (BlockMentionItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                emptyState
            } else {
                list
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 300)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        .zIndex(100)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, isSelected: index == selectedIndex)
                            .id(item.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
            .onChange(of: selectedIndex) { _, newValue in
                guard newValue >= 0, newValue < items.count else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(items[newValue].id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Text("No blocks")
                .font(.system(size: 13))
                .foregroundStyle(Palette.tertiaryForeground)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↑↓", "navigate")
            hint("↵", "select")
            hint("esc", "dismiss")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.foreground.opacity(0.7))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Palette.secondaryBackground, in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Palette.tertiaryForeground)
        }
    }

    private func row(_ item: BlockMentionItem, isSelected: Bool) -> some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Palette.accent.opacity(0.16) : Palette.secondaryBackground.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "doc.text")
                            .font(.system(size: 14))
                            .foregroundStyle(isSelected ? Palette.accent : Palette.tertiaryForeground)
                    )
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color(Palette.editorForeground))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Palette.accent.opacity(0.12) : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.accent)
                        .frame(width: 3, height: 22)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
    }

    static func filtered(mentionState: MentionState?, mentionableBlocks: [BlockMentionItem]) -> [BlockMentionItem] {
        guard let state = mentionState else { return [] }
        let query = state.filter.lowercased()
        if query.isEmpty { return Array(mentionableBlocks.prefix(8)) }
        return mentionableBlocks.enumerated()
            .compactMap { pair -> (score: Int, order: Int, item: BlockMentionItem)? in
                guard let s = score(pair.element, query: query) else { return nil }
                return (s, pair.offset, pair.element)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(8)
            .map { $0.item }
    }

    private static func score(_ item: BlockMentionItem, query: String) -> Int? {
        let title = item.title.lowercased()
        if title == query { return 1000 }
        if title.hasPrefix(query) { return 800 }
        if title.contains(query) { return 500 }
        if isSubsequence(query, of: title) { return 200 }
        return nil
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for ch in needle {
            var matched = false
            while let h = iterator.next() {
                if h == ch { matched = true; break }
            }
            if !matched { return false }
        }
        return true
    }
}
