import SwiftUI

struct BacklinkItem: Identifiable {
    let id: String
    let title: String
    let contextSnippet: String
    let type: BlockType

    init(id: String, title: String, contextSnippet: String, type: BlockType = .fleeting) {
        self.id = id
        self.title = title
        self.contextSnippet = contextSnippet
        self.type = type
    }
}

struct BacklinksPanel: View {
    let blockTitle: String
    let isExpanded: Bool
    let backlinks: [BacklinkItem]
    let onToggle: () -> Void
    let onOpenBlock: (String) -> Void


    private var mocBacklinks: [BacklinkItem] {
        backlinks.filter { $0.type == .moc }
    }

    private var nonMOCBacklinks: [BacklinkItem] {
        backlinks.filter { $0.type != .moc }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Palette.border.opacity(0.1))
                .frame(height: 1)

            VStack(spacing: 0) {
                headerButton

                if isExpanded {
                    if !mocBacklinks.isEmpty {
                        mocSection
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    backlinksList
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(Palette.secondaryBackground.opacity(0.5))
        }
        .animation(.spring(response: 0.3), value: isExpanded)
    }

    private var mocSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .medium))
                Text("Aparece em MOCs")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(mocBacklinks.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Palette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.accent.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            VStack(spacing: 0) {
                ForEach(mocBacklinks) { item in
                    backlinkRow(item)
                }
            }

            Rectangle()
                .fill(Palette.border.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 4)
        }
    }

    private var headerButton: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.spring(response: 0.3), value: isExpanded)

                Image(systemName: "link")
                    .font(.system(size: 11, weight: .medium))

                Text("Backlinks")
                    .font(.system(size: 12, weight: .semibold))

                if !backlinks.isEmpty {
                    Text("\(backlinks.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.accent.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var backlinksList: some View {
        Group {
            if backlinks.isEmpty {
                emptyState
            } else if nonMOCBacklinks.isEmpty {
                EmptyView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(nonMOCBacklinks) { item in
                            backlinkRow(item)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Text("No backlinks found")
                .font(.system(size: 12))
                .foregroundColor(Palette.tertiaryForeground)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func backlinkRow(_ item: BacklinkItem) -> some View {
        Button {
            onOpenBlock(item.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.tertiaryForeground)
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Palette.foreground)
                        .lineLimit(1)
                }

                if !item.contextSnippet.isEmpty {
                    highlightedSnippet(item.contextSnippet, linkTitle: blockTitle)
                        .font(.system(size: 12))
                        .foregroundColor(Palette.tertiaryForeground)
                        .lineLimit(2)
                        .padding(.leading, 17)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func highlightedSnippet(_ snippet: String, linkTitle: String) -> Text {
        let searchPattern = "[[" + linkTitle + "]]"
        guard let range = snippet.range(of: searchPattern, options: .caseInsensitive) else {
            return Text(snippet)
        }
        let before = String(snippet[snippet.startIndex..<range.lowerBound])
        let match = String(snippet[range])
        let after = String(snippet[range.upperBound..<snippet.endIndex])
        return Text(before) + Text(match).foregroundColor(Palette.accent).bold() + Text(after)
    }

    static func extractContext(from markdown: String, for title: String) -> String {
        let pattern = "[[" + title + "]]"
        let lines = markdown.components(separatedBy: .newlines)
        for line in lines {
            if line.range(of: pattern, options: .caseInsensitive) != nil {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 120 {
                    return String(trimmed.prefix(120)) + "..."
                }
                return trimmed
            }
        }
        return ""
    }
}
