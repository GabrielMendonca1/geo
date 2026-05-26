import Foundation

enum BlockPrefixOutcome: Equatable {
    case convert(kind: EditorBlockKind, remainingContent: String)
    case insertCodeBlock
    case insertMathBlock
}

enum BlockPrefixDetector {
    static func detect(_ content: String) -> BlockPrefixOutcome? {
        guard content.hasSuffix(" ") else { return nil }

        if content == "# " { return .convert(kind: .heading(level: 1), remainingContent: "") }
        if content == "## " { return .convert(kind: .heading(level: 2), remainingContent: "") }
        if content == "### " { return .convert(kind: .heading(level: 3), remainingContent: "") }
        if content == "#### " { return .convert(kind: .heading(level: 4), remainingContent: "") }
        if content == "##### " { return .convert(kind: .heading(level: 5), remainingContent: "") }
        if content == "###### " { return .convert(kind: .heading(level: 6), remainingContent: "") }
        if content == "- " { return .convert(kind: .bulletItem(marker: "-"), remainingContent: "") }
        if content == "* " { return .convert(kind: .bulletItem(marker: "*"), remainingContent: "") }
        if content == "+ " { return .convert(kind: .bulletItem(marker: "+"), remainingContent: "") }
        if content == "> " { return .convert(kind: .blockquote, remainingContent: "") }
        if content == "[] " || content == "[ ] " { return .convert(kind: .checkboxItem(checked: false, marker: "-"), remainingContent: "") }
        if content == "[x] " || content == "[X] " { return .convert(kind: .checkboxItem(checked: true, marker: "-"), remainingContent: "") }
        if content == "``` " { return .insertCodeBlock }
        if content == "$$ " { return .insertMathBlock }

        if content.hasSuffix(". ") {
            let numPart = content.dropLast(2)
            if let number = Int(numPart) {
                return .convert(kind: .orderedItem(number: number), remainingContent: "")
            }
        }

        return nil
    }
}
