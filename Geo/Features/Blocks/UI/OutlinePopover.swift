import SwiftUI

struct OutlinePopover: View {
    let headings: [OutlineHeading]
    let onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Outline")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if headings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(headings) { heading in
                            row(for: heading)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 260)
    }

    private func row(for heading: OutlineHeading) -> some View {
        Button {
            onSelect(heading.blockId)
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Text(heading.title.isEmpty ? "Untitled" : heading.title)
                    .font(.system(size: 12, weight: heading.level <= 2 ? .medium : .regular))
                    .foregroundColor(heading.title.isEmpty ? Palette.tertiaryForeground : Palette.foreground)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, Self.leadingPad(forLevel: heading.level))
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .plainNoFocusButton()
    }

    static func leadingPad(forLevel level: Int) -> CGFloat {
        let clamped = min(max(level, 1), 4)
        return 12 + CGFloat(clamped - 1) * 12
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .font(.title3)
                .foregroundColor(Palette.tertiaryForeground)
            Text("Sem headings")
                .font(.system(size: 12))
                .foregroundColor(Palette.tertiaryForeground)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

struct OutlineHeading: Identifiable, Equatable {
    var id: UUID { blockId }
    let blockId: UUID
    let level: Int
    let title: String
}

enum OutlineExtractor {
    static func headings(from blocks: [EditorBlock]) -> [OutlineHeading] {
        blocks.compactMap { block in
            guard case .heading(let level) = block.kind else { return nil }
            let trimmed = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return OutlineHeading(blockId: block.id, level: level, title: trimmed)
        }
    }
}
