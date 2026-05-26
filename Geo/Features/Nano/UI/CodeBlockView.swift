import SwiftUI
import AppKit

struct CodeBlockView: View {
    let language: String?
    let code: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var copied: Bool = false
    @State private var hovered: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(blockBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovered = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text((language?.isEmpty == false ? language! : "text").lowercased())
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if hovered || copied {
                Button(action: copy) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
    }

    private var blockBackground: Color {
        let pair = SyntaxHighlighter.codeBlockBackground
        return Color(colorScheme == .dark ? pair.dark : pair.light)
    }

    private var highlighted: AttributedString {
        let tokens = SyntaxHighlighter.highlight(code: code, language: language)
        var attr = AttributedString(code)
        let nsCode = code as NSString
        let baseColor: Color = colorScheme == .dark
            ? Color(red: 0.88, green: 0.89, blue: 0.91)
            : Color(red: 0.13, green: 0.14, blue: 0.16)
        attr.foregroundColor = baseColor
        for token in tokens {
            guard token.range.location >= 0,
                  NSMaxRange(token.range) <= nsCode.length else { continue }
            let utf16Start = code.utf16.index(code.utf16.startIndex, offsetBy: token.range.location, limitedBy: code.utf16.endIndex)
            let utf16End = code.utf16.index(code.utf16.startIndex, offsetBy: NSMaxRange(token.range), limitedBy: code.utf16.endIndex)
            guard let start = utf16Start, let end = utf16End,
                  let stringStart = String.Index(start, within: code),
                  let stringEnd = String.Index(end, within: code) else { continue }
            let substring = String(code[stringStart..<stringEnd])
            guard let attrRange = attr.range(of: substring) else { continue }
            let nsColor = SyntaxHighlighter.colorForToken(token.type, isDark: colorScheme == .dark)
            attr[attrRange].foregroundColor = Color(nsColor)
        }
        return attr
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
