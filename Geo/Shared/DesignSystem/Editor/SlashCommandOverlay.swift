import SwiftUI

struct SlashCommandOverlay: View {
    let commands: [BlockSlashCommand]
    let selectedIndex: Int
    let onSelect: (BlockSlashCommand) -> Void

    private var displayItems: [DisplayItem] {
        let capped = Array(commands.prefix(12))
        var items: [DisplayItem] = []
        var lastSection: BlockSlashCommand.Section?
        for (i, cmd) in capped.enumerated() {
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(displayItems) { item in
                    switch item {
                    case .header(let title):
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.tertiaryForeground)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    case .command(let index, let cmd):
                        commandRow(cmd, isSelected: index == selectedIndex)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 280)
        .frame(maxHeight: 340)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .zIndex(100)
    }

    private func commandRow(_ cmd: BlockSlashCommand, isSelected: Bool) -> some View {
        Button {
            onSelect(cmd)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Palette.accent.opacity(0.15) : Palette.secondaryBackground.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: cmd.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(isSelected ? Palette.accent : Palette.tertiaryForeground)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(cmd.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(Palette.editorForeground))
                    Text(cmd.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiaryForeground)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Palette.accent.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    static func filtered(for blockId: UUID, slashState: SlashState?) -> [BlockSlashCommand] {
        guard let state = slashState, state.blockId == blockId else { return [] }
        if state.filter.isEmpty { return BlockSlashCommand.all }
        let query = state.filter.lowercased()
        return BlockSlashCommand.all.filter { cmd in
            cmd.label.lowercased().contains(query) ||
            cmd.id.lowercased().contains(query) ||
            cmd.aliases.contains(where: { $0.lowercased().contains(query) })
        }
    }
}
