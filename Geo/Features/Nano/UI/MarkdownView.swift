import SwiftUI
import Markdown

struct MarkdownView: View {
    let source: String
    let baseSize: CGFloat

    init(_ source: String, baseSize: CGFloat = 14) {
        self.source = source
        self.baseSize = baseSize
    }

    var body: some View {
        let document = Document(parsing: source, options: [])
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(document.children.enumerated()), id: \.offset) { _, child in
                blockView(for: child)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func blockView(for markup: any Markup) -> AnyView {
        switch markup {
        case let heading as Heading:
            return AnyView(headingView(heading))
        case let paragraph as Paragraph:
            return AnyView(
                paragraphText(paragraph.format())
                    .font(.system(size: baseSize))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            )
        case let codeBlock as CodeBlock:
            return AnyView(CodeBlockView(language: codeBlock.language, code: codeBlock.code))
        case let list as UnorderedList:
            return AnyView(listView(items: Array(list.listItems), ordered: false))
        case let list as OrderedList:
            return AnyView(listView(items: Array(list.listItems), ordered: true))
        case let blockquote as BlockQuote:
            return AnyView(blockquoteView(blockquote))
        case is ThematicBreak:
            return AnyView(Divider().padding(.vertical, 4))
        case let html as HTMLBlock:
            return AnyView(
                paragraphText(html.rawHTML)
                    .font(.system(size: baseSize - 1, design: .monospaced))
                    .foregroundStyle(.secondary)
            )
        default:
            return AnyView(
                paragraphText(markup.format())
                    .font(.system(size: baseSize))
                    .foregroundStyle(.primary)
            )
        }
    }

    private func headingView(_ heading: Heading) -> some View {
        let level = max(1, min(heading.level, 6))
        let size: CGFloat = {
            switch level {
            case 1: return baseSize + 8
            case 2: return baseSize + 6
            case 3: return baseSize + 4
            case 4: return baseSize + 2
            default: return baseSize
            }
        }()
        let weight: Font.Weight = level <= 2 ? .bold : .semibold
        return paragraphText(heading.plainText)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.primary)
            .padding(.top, level <= 2 ? 6 : 2)
    }

    private func listView(items: [ListItem], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .top, spacing: 8) {
                    SwiftUI.Text(ordered ? "\(idx + 1)." : "•")
                        .font(.system(size: baseSize))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 14, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            blockView(for: child)
                        }
                    }
                }
            }
        }
    }

    private func blockquoteView(_ quote: BlockQuote) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(quote.children.enumerated()), id: \.offset) { _, child in
                    blockView(for: child)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func paragraphText(_ markdownSource: String) -> SwiftUI.Text {
        do {
            let attr = try AttributedString(
                markdown: markdownSource,
                options: AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: false,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
            return SwiftUI.Text(attr)
        } catch {
            return SwiftUI.Text(markdownSource)
        }
    }
}
