import SwiftUI

struct SlashCommandOverlay: View {
    let commands: [BlockSlashCommand]
    let selectedIndex: Int
    let query: String
    let onSelect: (BlockSlashCommand) -> Void

    private var showSections: Bool { query.isEmpty }

    private var displayItems: [DisplayItem] {
        guard showSections else {
            return commands.enumerated().map { .command(index: $0.offset, cmd: $0.element) }
        }
        var items: [DisplayItem] = []
        var lastSection: BlockSlashCommand.Section?
        for (i, cmd) in commands.enumerated() {
            if cmd.section != lastSection {
                items.append(.header(cmd.section.rawValue))
                lastSection = cmd.section
            }
            items.append(.command(index: i, cmd: cmd))
        }
        return items
    }

    private enum DisplayItem: Identifiable {
        case header(String)
        case command(index: Int, cmd: BlockSlashCommand)

        var id: String {
            switch self {
            case .header(let s): return "h_\(s)"
            case .command(_, let cmd): return cmd.id
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if commands.isEmpty {
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
                    ForEach(displayItems) { item in
                        switch item {
                        case .header(let title):
                            Text(title.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .kerning(0.5)
                                .foregroundStyle(Palette.tertiaryForeground.opacity(0.8))
                                .padding(.horizontal, 14)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                        case .command(let index, let cmd):
                            commandRow(cmd, isSelected: index == selectedIndex)
                                .id(cmd.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
            .onChange(of: selectedIndex) { _, newValue in
                guard newValue >= 0, newValue < commands.count else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(commands[newValue].id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Text("No commands")
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

    private func commandRow(_ cmd: BlockSlashCommand, isSelected: Bool) -> some View {
        Button {
            onSelect(cmd)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Palette.accent.opacity(0.16) : Palette.secondaryBackground.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: cmd.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(isSelected ? Palette.accent : Palette.tertiaryForeground)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(cmd.label)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Color(Palette.editorForeground))
                    Text(cmd.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiaryForeground)
                        .lineLimit(1)
                }
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

    static func filtered(for blockId: UUID, slashState: SlashState?) -> [BlockSlashCommand] {
        guard let state = slashState, state.blockId == blockId else { return [] }
        let query = state.filter.lowercased()
        if query.isEmpty { return BlockSlashCommand.all }
        return BlockSlashCommand.all.enumerated()
            .compactMap { pair -> (score: Int, order: Int, cmd: BlockSlashCommand)? in
                guard let s = score(pair.element, query: query) else { return nil }
                return (s, pair.offset, pair.element)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(8)
            .map { $0.cmd }
    }

    /// Ranks a command against the query: exact/prefix/alias beat substring beat subsequence.
    /// Returns nil when there is no match at all.
    private static func score(_ cmd: BlockSlashCommand, query: String) -> Int? {
        let label = cmd.label.lowercased()
        if label == query { return 1000 }
        if label.hasPrefix(query) { return 850 }
        if cmd.aliases.contains(where: { $0.lowercased() == query }) { return 800 }
        if cmd.aliases.contains(where: { $0.lowercased().hasPrefix(query) }) { return 650 }
        if label.contains(query) { return 500 }
        if cmd.aliases.contains(where: { $0.lowercased().contains(query) }) { return 400 }
        if isSubsequence(query, of: label) { return 200 }
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
