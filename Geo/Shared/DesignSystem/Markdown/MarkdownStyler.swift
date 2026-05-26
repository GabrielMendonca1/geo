import Foundation
import Markdown

struct StyleRange {
    let range: NSRange
    let style: MarkdownStyle
    let syntaxRanges: [NSRange]
}

enum MarkdownStyle {
    case heading(level: Int)
    case bold
    case italic
    case strikethrough
    case inlineCode
    case codeBlock(language: String?)
    case link(url: String, textRange: NSRange)
    case image(source: String, altText: String)
    case listItem(indent: Int, isOrdered: Bool, marker: String)
    case checkbox(checked: Bool, indent: Int)
    case blockquote
    case horizontalRule
    case table
}

final class MarkdownStyler {
    private let source: String
    private let nsSource: NSString
    private var results: [StyleRange] = []
    private var lineStarts: [Int] = []

    private static let imageRegex = try! NSRegularExpression(pattern: #"^!\[(.*?)\]\((.*?)\)$"#, options: [])
    private static let checkboxMarkerRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:[-*+])\s+|\d+\.\s+)?\[(?: |x|X)\]"#,
        options: []
    )

    init(source: String) {
        self.source = source
        self.nsSource = source as NSString
    }

    func style() -> [StyleRange] {
        results.removeAll()
        lineStarts = computeLineStarts()
        let document = Document(parsing: source, options: [.parseBlockDirectives, .parseSymbolLinks])
        walkMarkup(document)
        return results
    }

    private func computeLineStarts() -> [Int] {
        var starts = [0]
        for (i, char) in source.utf16.enumerated() {
            if char == 0x0A {
                starts.append(i + 1)
            }
        }
        return starts
    }

    private func walkMarkup(_ markup: Markup) {
        switch markup {
        case let heading as Heading: handleHeading(heading)
        case is Strong: handleSymmetric(markup, style: .bold, markerWidth: 2, recurse: true)
        case is Emphasis: handleSymmetric(markup, style: .italic, markerWidth: 1, recurse: true)
        case is Strikethrough: handleSymmetric(markup, style: .strikethrough, markerWidth: 2, recurse: true)
        case is InlineCode: handleSymmetric(markup, style: .inlineCode, markerWidth: 1, recurse: false)
        case let codeBlock as CodeBlock: handleCodeBlock(codeBlock)
        case let link as Link: handleLink(link)
        case let image as Image: handleImage(image)
        case let listItem as ListItem: handleListItem(listItem)
        case let blockQuote as BlockQuote: handleBlockQuote(blockQuote)
        case let thematicBreak as ThematicBreak: handleThematicBreak(thematicBreak)
        case let table as Table: handleTable(table)
        default:
            for child in markup.children { walkMarkup(child) }
        }
    }

    private func handleHeading(_ heading: Heading) {
        guard let range = nsRange(for: heading) else { return }

        var syntaxRanges: [NSRange] = []
        let lineRange = nsSource.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = nsSource.substring(with: lineRange)

        if let hashEnd = lineText.firstIndex(of: " ") {
            let hashLength = lineText.distance(from: lineText.startIndex, to: hashEnd) + 1
            syntaxRanges.append(NSRange(location: lineRange.location, length: hashLength))
        }

        results.append(StyleRange(range: range, style: .heading(level: heading.level), syntaxRanges: syntaxRanges))

        for child in heading.children {
            walkMarkup(child)
        }
    }

    private func handleSymmetric(_ markup: Markup, style: MarkdownStyle, markerWidth: Int, recurse: Bool) {
        guard let range = nsRange(for: markup) else { return }
        var syntaxRanges: [NSRange] = []
        if range.length >= markerWidth * 2 {
            syntaxRanges.append(NSRange(location: range.location, length: markerWidth))
            syntaxRanges.append(NSRange(location: range.location + range.length - markerWidth, length: markerWidth))
        }
        results.append(StyleRange(range: range, style: style, syntaxRanges: syntaxRanges))
        if recurse {
            for child in markup.children { walkMarkup(child) }
        }
    }

    private func handleCodeBlock(_ codeBlock: CodeBlock) {
        guard let range = nsRange(for: codeBlock) else { return }

        var syntaxRanges: [NSRange] = []
        let lineRange = nsSource.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = nsSource.substring(with: lineRange)

        if lineText.hasPrefix("```") {
            let langLength = lineText.trimmingCharacters(in: .newlines).count
            syntaxRanges.append(NSRange(location: lineRange.location, length: langLength))
        }

        let blockText = nsSource.substring(with: range)
        if let fenceRange = blockText.range(of: "```", options: .backwards) {
            let fenceOffset = blockText.distance(from: blockText.startIndex, to: fenceRange.lowerBound)
            let fenceNSOffset = (blockText.prefix(fenceOffset) as NSString).length
            syntaxRanges.append(NSRange(location: range.location + fenceNSOffset, length: 3))
        }

        results.append(StyleRange(range: range, style: .codeBlock(language: codeBlock.language), syntaxRanges: syntaxRanges))
    }

    private func handleLink(_ link: Link) {
        guard let range = nsRange(for: link) else { return }
        let linkText = nsSource.substring(with: range)
        guard let parts = findLinkParts(in: linkText) else {
            for child in link.children { walkMarkup(child) }
            return
        }
        let syntaxRanges: [NSRange] = [
            NSRange(location: range.location, length: 1),
            NSRange(location: range.location + parts.closeBracket, length: 1),
            NSRange(location: range.location + parts.openParen, length: parts.closeParen - parts.openParen + 1),
        ]
        let textRange = NSRange(location: range.location + 1, length: max(0, parts.closeBracket - 1))
        results.append(StyleRange(range: range, style: .link(url: link.destination ?? "", textRange: textRange), syntaxRanges: syntaxRanges))
        for child in link.children { walkMarkup(child) }
    }

    private func findLinkParts(in text: String) -> (closeBracket: Int, openParen: Int, closeParen: Int)? {
        guard text.hasPrefix("[") else { return nil }
        var depth = 0
        var closeBracketIdx: String.Index?
        for idx in text.indices {
            switch text[idx] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { closeBracketIdx = idx }
            default: break
            }
            if closeBracketIdx != nil { break }
        }
        guard let cb = closeBracketIdx else { return nil }
        let afterCB = text.index(after: cb)
        guard afterCB < text.endIndex, text[afterCB] == "(" else { return nil }
        guard let closeParen = text.lastIndex(of: ")") else { return nil }
        return (
            text.distance(from: text.startIndex, to: cb),
            text.distance(from: text.startIndex, to: afterCB),
            text.distance(from: text.startIndex, to: closeParen)
        )
    }

    private func handleImage(_ image: Image) {
        guard let range = nsRange(for: image) else { return }
        let imageText = nsSource.substring(with: range)
        let nsImageText = imageText as NSString
        let fullRange = NSRange(location: 0, length: nsImageText.length)

        guard let match = Self.imageRegex.firstMatch(in: imageText, options: [], range: fullRange) else {
            return
        }

        let altRange = match.range(at: 1)
        let sourceRange = match.range(at: 2)
        guard altRange.location != NSNotFound, sourceRange.location != NSNotFound else { return }

        var source = nsImageText.substring(with: sourceRange).trimmingCharacters(in: .whitespacesAndNewlines)
        let altText = nsImageText.substring(with: altRange).trimmingCharacters(in: .whitespacesAndNewlines)

        if source.hasPrefix("<"), source.hasSuffix(">"), source.count > 2 {
            source.removeFirst()
            source.removeLast()
        }

        results.append(StyleRange(range: range, style: .image(source: source, altText: altText), syntaxRanges: []))
    }

    private func handleListItem(_ listItem: ListItem) {
        guard let range = nsRange(for: listItem) else { return }

        let lineRange = nsSource.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = nsSource.substring(with: lineRange)

        let indent = countIndent(lineText)
        let isOrdered = listItem.parent is OrderedList

        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked
            var syntaxRanges: [NSRange] = []

            if let markerRange = findCheckboxMarker(in: lineText, at: lineRange.location) {
                syntaxRanges.append(markerRange)
            }

            results.append(StyleRange(range: range, style: .checkbox(checked: checked, indent: indent), syntaxRanges: syntaxRanges))
        } else {
            var syntaxRanges: [NSRange] = []
            let marker: String

            if isOrdered {
                marker = extractOrderedMarker(from: lineText)
                if let markerRange = findOrderedMarker(in: lineText, at: lineRange.location) {
                    syntaxRanges.append(markerRange)
                }
            } else {
                marker = extractBulletMarker(from: lineText)
                if let markerRange = findBulletMarker(in: lineText, at: lineRange.location) {
                    syntaxRanges.append(markerRange)
                }
            }

            results.append(StyleRange(range: range, style: .listItem(indent: indent, isOrdered: isOrdered, marker: marker), syntaxRanges: syntaxRanges))
        }

        for child in listItem.children {
            walkMarkup(child)
        }
    }

    private func handleBlockQuote(_ blockQuote: BlockQuote) {
        guard let range = nsRange(for: blockQuote) else { return }

        var syntaxRanges: [NSRange] = []
        var index = range.location
        let endIndex = range.location + range.length

        while index < endIndex && index < nsSource.length {
            let lineRange = nsSource.lineRange(for: NSRange(location: index, length: 0))
            let lineText = nsSource.substring(with: lineRange)

            if let prefixRange = blockquotePrefixSyntaxRange(in: lineText, at: lineRange.location) {
                syntaxRanges.append(prefixRange)
            }

            index = NSMaxRange(lineRange)
        }

        results.append(StyleRange(range: range, style: .blockquote, syntaxRanges: syntaxRanges))

        for child in blockQuote.children {
            walkMarkup(child)
        }
    }

    private func blockquotePrefixSyntaxRange(in text: String, at lineStart: Int) -> NSRange? {
        guard !text.isEmpty else { return nil }

        var idx = text.startIndex
        var foundQuoteMarker = false

        while idx < text.endIndex {
            while idx < text.endIndex && (text[idx] == " " || text[idx] == "\t") {
                idx = text.index(after: idx)
            }

            guard idx < text.endIndex, text[idx] == ">" else { break }

            foundQuoteMarker = true
            idx = text.index(after: idx)

            if idx < text.endIndex, text[idx] == " " {
                idx = text.index(after: idx)
            }
        }

        guard foundQuoteMarker else { return nil }
        let hiddenLength = text.distance(from: text.startIndex, to: idx)
        guard hiddenLength > 0 else { return nil }
        return NSRange(location: lineStart, length: hiddenLength)
    }

    private func handleThematicBreak(_ thematicBreak: ThematicBreak) {
        guard let range = nsRange(for: thematicBreak) else { return }
        let lineRange = nsSource.lineRange(for: range)
        results.append(StyleRange(range: lineRange, style: .horizontalRule, syntaxRanges: [lineRange]))
    }

    private func handleTable(_ table: Table) {
        guard let range = nsRange(for: table) else { return }
        results.append(StyleRange(range: range, style: .table, syntaxRanges: []))
    }

    private func nsRange(for markup: Markup) -> NSRange? {
        guard let sourceRange = markup.range else { return nil }

        let startLine = sourceRange.lowerBound.line - 1
        let startColumn = sourceRange.lowerBound.column - 1
        let endLine = sourceRange.upperBound.line - 1
        let endColumn = sourceRange.upperBound.column - 1

        let startOffset: Int
        if startLine < lineStarts.count {
            startOffset = utf16Offset(forUTF8Column: startColumn, line: startLine)
        } else {
            startOffset = nsSource.length
        }

        let endOffset: Int
        if endLine < lineStarts.count {
            endOffset = utf16Offset(forUTF8Column: endColumn, line: endLine)
        } else {
            endOffset = nsSource.length
        }

        let length = max(0, endOffset - startOffset)
        guard startOffset >= 0 && startOffset + length <= nsSource.length else { return nil }

        return NSRange(location: startOffset, length: length)
    }

    private func utf16Offset(forUTF8Column column: Int, line: Int) -> Int {
        guard line >= 0, line < lineStarts.count else { return nsSource.length }

        let lineStart = lineStarts[line]
        let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] : nsSource.length
        guard column > 0 else { return lineStart }

        let clampedStart = max(0, min(lineStart, nsSource.length))
        let clampedEnd = max(clampedStart, min(lineEnd, nsSource.length))
        let lineRange = NSRange(location: clampedStart, length: clampedEnd - clampedStart)
        guard lineRange.length > 0 else { return clampedStart }

        let lineText = nsSource.substring(with: lineRange)
        let targetUTF8Bytes = min(column, lineText.utf8.count)

        var consumedUTF8 = 0
        var consumedUTF16 = 0
        for scalar in lineText.unicodeScalars {
            let scalarUTF8Length = scalar.utf8.count
            if consumedUTF8 + scalarUTF8Length > targetUTF8Bytes {
                break
            }
            consumedUTF8 += scalarUTF8Length
            consumedUTF16 += scalar.utf16.count
            if consumedUTF8 == targetUTF8Bytes {
                break
            }
        }

        return min(clampedStart + consumedUTF16, clampedEnd)
    }

    private func countIndent(_ text: String) -> Int {
        var count = 0
        for char in text {
            if char == " " { count += 1 }
            else if char == "\t" { count += 2 }
            else { break }
        }
        return count / 2
    }

    private func extractBulletMarker(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("-") { return "-" }
        if trimmed.hasPrefix("*") { return "*" }
        if trimmed.hasPrefix("+") { return "+" }
        return "-"
    }

    private func extractOrderedMarker(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let dotIndex = trimmed.firstIndex(of: ".") {
            return String(trimmed[..<trimmed.index(after: dotIndex)])
        }
        return "1."
    }

    private func findBulletMarker(in text: String, at lineStart: Int) -> NSRange? {
        for (i, char) in text.enumerated() {
            if char == "-" || char == "*" || char == "+" {
                let nextIdx = text.index(text.startIndex, offsetBy: i + 1, limitedBy: text.endIndex)
                let hasSpaceAfter = nextIdx.map { $0 < text.endIndex && text[$0] == " " } ?? false
                let length = hasSpaceAfter ? 2 : 1
                return NSRange(location: lineStart + i, length: length)
            }
            if !char.isWhitespace { break }
        }
        return nil
    }

    private func findOrderedMarker(in text: String, at lineStart: Int) -> NSRange? {
        var startIdx: Int?
        for (i, char) in text.enumerated() {
            if char.isNumber {
                if startIdx == nil { startIdx = i }
            } else if char == "." {
                if let start = startIdx {
                    let afterDot = i + 1
                    let hasSpace = afterDot < text.count && text[text.index(text.startIndex, offsetBy: afterDot)] == " "
                    let length = (i - start + 1) + (hasSpace ? 1 : 0)
                    return NSRange(location: lineStart + start, length: length)
                }
                break
            } else if !char.isWhitespace {
                break
            }
        }
        return nil
    }

    private func findCheckboxMarker(in text: String, at lineStart: Int) -> NSRange? {
        let nsText = text as NSString
        let searchRange = NSRange(location: 0, length: nsText.length)
        guard let match = Self.checkboxMarkerRegex.firstMatch(in: text, options: [], range: searchRange) else { return nil }
        return NSRange(location: lineStart + match.range.location, length: match.range.length)
    }
}
