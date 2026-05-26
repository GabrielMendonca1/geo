import SwiftUI

struct EditorStatusBar: View, Equatable {
    let words: Int
    let minutes: Int

    var body: some View {
        HStack(spacing: 6) {
            Spacer()
            Text(summary)
                .font(.system(size: 11))
                .foregroundColor(Palette.tertiaryForeground.opacity(0.75))
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var summary: String {
        let wordLabel = words == 1 ? "word" : "words"
        return "\(words) \(wordLabel) • \(minutes) min"
    }

    private var accessibilityLabel: String {
        "\(words) words, \(minutes) minute read"
    }

    static func == (lhs: EditorStatusBar, rhs: EditorStatusBar) -> Bool {
        lhs.words == rhs.words && lhs.minutes == rhs.minutes
    }

    static func compute(markdown: String) -> (words: Int, minutes: Int) {
        var stripped = markdown
        let patterns = [
            "(?m)^#{1,6}\\s+",
            "(?m)^>\\s+",
            "(?m)^[-*+]\\s+",
            "(?m)^\\d+\\.\\s+",
            "(?m)^\\[[ xX]?\\]\\s+",
            "\\*\\*|__|~~|==|`",
            "\\[\\[|\\]\\]",
            "\\[(.*?)\\]\\((.*?)\\)"
        ]
        for pat in patterns {
            stripped = stripped.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
        }
        let words = stripped
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { !$0.isEmpty }
            .count
        let minutes = max(1, Int((Double(words) / 220.0).rounded(.up)))
        return (words, minutes)
    }
}
