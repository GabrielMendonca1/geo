import Foundation
import SwiftUI

enum CalloutType: String, CaseIterable, Equatable, Hashable {
    case tip, info, warning, danger, note, quote, example, bug, success, question, abstract, todo

    var icon: String {
        switch self {
        case .tip: return "lightbulb.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        case .note: return "pencil.circle.fill"
        case .quote: return "quote.opening"
        case .example: return "list.bullet.rectangle"
        case .bug: return "ladybug.fill"
        case .success: return "checkmark.circle.fill"
        case .question: return "questionmark.circle.fill"
        case .abstract: return "doc.text.fill"
        case .todo: return "checklist"
        }
    }

    var color: Color {
        switch self {
        case .tip: return Color(red: 0.0, green: 0.72, blue: 0.58)
        case .info: return Color(red: 0.04, green: 0.52, blue: 0.89)
        case .warning: return Color(red: 0.99, green: 0.80, blue: 0.43)
        case .danger: return Color(red: 0.84, green: 0.19, blue: 0.19)
        case .note: return Color(red: 0.42, green: 0.36, blue: 0.91)
        case .quote: return Color(red: 0.39, green: 0.43, blue: 0.45)
        case .example: return Color(red: 0.0, green: 0.81, blue: 0.79)
        case .bug: return Color(red: 0.88, green: 0.44, blue: 0.33)
        case .success: return Color(red: 0.0, green: 0.72, blue: 0.58)
        case .question: return Color(red: 0.99, green: 0.80, blue: 0.43)
        case .abstract: return Color(red: 0.45, green: 0.73, blue: 1.0)
        case .todo: return Color(red: 0.04, green: 0.52, blue: 0.89)
        }
    }

    var displayName: String {
        rawValue.capitalized
    }
}

enum EditorBlockKind: Equatable, Hashable {
    case paragraph
    case heading(level: Int)
    case blockquote
    case bulletItem(marker: String)
    case orderedItem(number: Int)
    case checkboxItem(checked: Bool, marker: String)
    case codeBlock(language: String?)
    case horizontalRule
    case table
    case image(alt: String, url: String)
    case callout(type: CalloutType, title: String?)
    case toggle(expanded: Bool)
    case mathBlock
    case empty
}

struct EditorBlock: Identifiable, Equatable, Hashable {
    var id: UUID
    var kind: EditorBlockKind
    var sourceRange: NSRange
    var rawText: String
    var indent: String
    var prefix: String
    var contentRange: NSRange
    var collapsed: Bool = false
    var depth: Int = 0
    var parentId: UUID? = nil
    /// True when this list/checkbox lives inside a blockquote (`> - item`,
    /// `> 1. [ ] task`). Rendering adds the quote bar to the chrome; serialization
    /// preserves the `> ` marker via the `prefix` field.
    var insideBlockquote: Bool = false
    var cleanContent: String?
    var spans: [InlineSpan] = []

    private var trailingNewline: String {
        rawText.hasSuffix("\n") ? "\n" : ""
    }

    var content: String {
        if let clean = cleanContent { return clean }
        let offset = contentRange.location - sourceRange.location
        let ns = rawText as NSString
        guard offset >= 0, offset <= ns.length else { return rawText }
        var c = ns.substring(from: offset)
        if c.hasSuffix("\n") { c = String(c.dropLast()) }
        return c
    }

    var mathContent: String? {
        guard case .mathBlock = kind else { return nil }
        var lines = rawText.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count >= 2 else { return "" }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "$$" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    func withMathContent(_ newContent: String) -> EditorBlock {
        guard case .mathBlock = kind else { return self }
        var copy = self
        copy.rawText = "$$\n" + newContent + "\n$$\n"
        copy.sourceRange = NSRange(location: sourceRange.location, length: (copy.rawText as NSString).length)
        let opener = "$$\n"
        copy.contentRange = NSRange(location: sourceRange.location + (opener as NSString).length, length: (newContent as NSString).length)
        return copy
    }

    var codeLanguage: String? {
        guard case .codeBlock(let lang) = kind else { return nil }
        return lang
    }

    var codeContent: String? {
        guard case .codeBlock = kind else { return nil }
        var lines = rawText.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count >= 2 else { return "" }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    var exitsOnEmptyEnter: Bool {
        switch kind {
        case .bulletItem, .orderedItem, .checkboxItem, .blockquote, .callout, .toggle: return true
        default: return false
        }
    }

    var calloutContent: String? {
        guard case .callout = kind else { return nil }
        let lines = rawText.components(separatedBy: "\n")
        var contentLines: [String] = []
        for (i, line) in lines.enumerated() {
            if i == 0 { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && i == lines.count - 1 { continue }
            if line.hasPrefix("> ") {
                contentLines.append(String(line.dropFirst(2)))
            } else if line == ">" {
                contentLines.append("")
            } else {
                contentLines.append(line)
            }
        }
        return contentLines.joined(separator: "\n")
    }

    func withCalloutContent(_ newContent: String) -> EditorBlock {
        guard case .callout(let type, let title) = kind else { return self }
        var copy = self
        let header: String
        if let nl = rawText.firstIndex(of: "\n") {
            header = String(rawText[...nl])
        } else {
            header = "> [!\(type.rawValue)]" + (title.map { " \($0)" } ?? "") + "\n"
        }
        let bodyLines = newContent.components(separatedBy: "\n")
        let body = bodyLines.map { "> \($0)" }.joined(separator: "\n")
        copy.rawText = header + body + "\n"
        copy.sourceRange = NSRange(location: sourceRange.location, length: (copy.rawText as NSString).length)
        copy.contentRange = NSRange(location: sourceRange.location + (header as NSString).length, length: (body as NSString).length)
        return copy
    }

    private static let toggleTitleRegex = try! NSRegularExpression(pattern: "^>>\\s*\\[(>|v)\\]\\s*(.*)")

    var toggleTitle: String? {
        guard case .toggle = kind else { return nil }
        let lines = rawText.components(separatedBy: "\n")
        guard let first = lines.first else { return nil }
        let ns = first as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = Self.toggleTitleRegex.firstMatch(in: first, range: range) else { return nil }
        if match.range(at: 2).location != NSNotFound {
            return ns.substring(with: match.range(at: 2))
        }
        return ""
    }

    var toggleContent: String? {
        guard case .toggle = kind else { return nil }
        let lines = rawText.components(separatedBy: "\n")
        var contentLines: [String] = []
        for (i, line) in lines.enumerated() {
            if i == 0 { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && i == lines.count - 1 { continue }
            if line.hasPrefix(">> ") {
                contentLines.append(String(line.dropFirst(3)))
            } else if line == ">>" {
                contentLines.append("")
            } else {
                contentLines.append(line)
            }
        }
        return contentLines.joined(separator: "\n")
    }

    func withToggleContent(_ newContent: String) -> EditorBlock {
        guard case .toggle(let expanded) = kind else { return self }
        var copy = self
        let marker = expanded ? "v" : ">"
        let title = toggleTitle ?? ""
        let header = ">>[\(marker)] \(title)\n"
        let bodyLines = newContent.components(separatedBy: "\n")
        let body = bodyLines.map { ">> \($0)" }.joined(separator: "\n")
        copy.rawText = header + body + "\n"
        copy.sourceRange = NSRange(location: sourceRange.location, length: (copy.rawText as NSString).length)
        copy.contentRange = NSRange(location: sourceRange.location + (header as NSString).length, length: (body as NSString).length)
        return copy
    }

    func withToggleState(expanded: Bool) -> EditorBlock {
        guard case .toggle = kind else { return self }
        var copy = self
        copy.kind = .toggle(expanded: expanded)
        let newMarker = expanded ? "v" : ">"
        let regex = try? NSRegularExpression(pattern: "^(>>\\s*\\[)(>|v)(\\])", options: [])
        let ns = copy.rawText as NSString
        if let regex,
           let match = regex.firstMatch(in: copy.rawText, range: NSRange(location: 0, length: ns.length)) {
            let markerRange = match.range(at: 2)
            let mutable = NSMutableString(string: copy.rawText)
            mutable.replaceCharacters(in: markerRange, with: newMarker)
            copy.rawText = mutable as String
        }
        return copy
    }

    static func toggle(title: String = "", content: String = "", expanded: Bool = true) -> EditorBlock {
        let marker = expanded ? "v" : ">"
        let header = ">>[\(marker)] \(title)\n"
        let bodyLines = content.isEmpty ? [""] : content.components(separatedBy: "\n")
        let body = bodyLines.map { ">> \($0)" }.joined(separator: "\n")
        let raw = header + body + "\n"
        var block = EditorBlock(
            id: UUID(), kind: .toggle(expanded: expanded),
            sourceRange: NSRange(location: 0, length: (raw as NSString).length),
            rawText: raw, indent: "", prefix: "",
            contentRange: NSRange(location: (header as NSString).length, length: (body as NSString).length)
        )
        block.cleanContent = content
        return block
    }

    static func callout(type: CalloutType, title: String? = nil, content: String = "") -> EditorBlock {
        let header = "> [!\(type.rawValue)]" + (title.map { " \($0)" } ?? "") + "\n"
        let bodyLines = content.isEmpty ? [""] : content.components(separatedBy: "\n")
        let body = bodyLines.map { "> \($0)" }.joined(separator: "\n")
        let raw = header + body + "\n"
        var block = EditorBlock(
            id: UUID(), kind: .callout(type: type, title: title),
            sourceRange: NSRange(location: 0, length: (raw as NSString).length),
            rawText: raw, indent: "", prefix: "",
            contentRange: NSRange(location: (header as NSString).length, length: (body as NSString).length)
        )
        block.cleanContent = content
        return block
    }

    func withContent(_ newContent: String, spans: [InlineSpan] = []) -> EditorBlock {
        rebuild(prefix: prefix, content: newContent, spans: spans)
    }

    func withCodeContent(_ newContent: String) -> EditorBlock {
        guard case .codeBlock(let lang) = kind else { return self }
        var copy = self
        let opener: String
        if let nl = rawText.firstIndex(of: "\n") {
            opener = String(rawText[...nl])
        } else {
            opener = "```\(lang ?? "")\n"
        }
        let closer: String
        if let lastNL = rawText.range(of: "\n", options: .backwards),
           let priorNL = rawText.range(of: "\n", options: .backwards, range: rawText.startIndex..<lastNL.lowerBound) {
            let closerLine = String(rawText[priorNL.upperBound...])
            if closerLine.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                closer = closerLine
            } else {
                closer = "```\n"
            }
        } else {
            closer = "```\n"
        }
        copy.rawText = opener + newContent + "\n" + closer
        copy.sourceRange = NSRange(location: sourceRange.location, length: (copy.rawText as NSString).length)
        copy.contentRange = NSRange(location: sourceRange.location + (opener as NSString).length, length: (newContent as NSString).length)
        return copy
    }

    func withKind(_ newKind: EditorBlockKind) -> EditorBlock {
        guard let newPrefix = Self.prefixString(for: newKind, indent: indent) else { return self }
        var copy = rebuild(prefix: newPrefix, content: content, spans: spans)
        copy.kind = newKind
        switch newKind {
        case .bulletItem, .orderedItem, .checkboxItem: break
        default: copy.depth = 0
        }
        return copy
    }

    func withIndent(_ newIndent: String) -> EditorBlock {
        let oldIndentLen = (indent as NSString).length
        let ns = prefix as NSString
        let kindSuffix = ns.length > oldIndentLen ? ns.substring(from: oldIndentLen) : ""
        var copy = rebuild(prefix: newIndent + kindSuffix, content: content, spans: spans)
        copy.indent = newIndent
        copy.depth = BlockTreeNavigator.depthFromIndent(newIndent)
        return copy
    }

    func withCheckedState(_ checked: Bool) -> EditorBlock {
        guard case .checkboxItem(_, let marker) = kind else { return self }
        return withKind(.checkboxItem(checked: checked, marker: marker))
    }

    func continuationBlock(content newContent: String, spans newSpans: [InlineSpan] = []) -> EditorBlock {
        let nextKind: EditorBlockKind
        let nextPrefix: String
        switch kind {
        case .bulletItem(let marker):
            nextKind = .bulletItem(marker: marker)
            nextPrefix = indent + marker + " "
        case .orderedItem(let number):
            nextKind = .orderedItem(number: number + 1)
            nextPrefix = indent + "\(number + 1). "
        case .checkboxItem(_, let marker):
            nextKind = .checkboxItem(checked: false, marker: marker)
            nextPrefix = indent + marker + " [ ] "
        case .blockquote:
            nextKind = .blockquote
            nextPrefix = indent + "> "
        default:
            nextKind = .paragraph
            nextPrefix = ""
        }
        let serialized = newSpans.isEmpty ? newContent : InlineSerializer.serialize(content: newContent, spans: newSpans)
        let raw = nextPrefix + serialized + "\n"
        var block = EditorBlock(
            id: UUID(), kind: nextKind,
            sourceRange: NSRange(location: 0, length: (raw as NSString).length),
            rawText: raw, indent: indent, prefix: nextPrefix,
            contentRange: NSRange(location: (nextPrefix as NSString).length, length: (serialized as NSString).length)
        )
        block.depth = depth
        block.cleanContent = newContent
        block.spans = newSpans
        return block
    }

    static func paragraph(content: String) -> EditorBlock {
        let raw = content + "\n"
        var block = EditorBlock(
            id: UUID(), kind: .paragraph,
            sourceRange: NSRange(location: 0, length: (raw as NSString).length),
            rawText: raw, indent: "", prefix: "",
            contentRange: NSRange(location: 0, length: (content as NSString).length)
        )
        block.cleanContent = content
        return block
    }

    static func empty() -> EditorBlock {
        var block = EditorBlock(
            id: UUID(), kind: .empty,
            sourceRange: NSRange(location: 0, length: 1),
            rawText: "\n", indent: "", prefix: "",
            contentRange: NSRange(location: 0, length: 0)
        )
        block.cleanContent = ""
        return block
    }

    static func mathBlock(latex: String = "") -> EditorBlock {
        let raw = "$$\n" + latex + "\n$$\n"
        let prefixLen = ("$$\n" as NSString).length
        return EditorBlock(
            id: UUID(), kind: .mathBlock,
            sourceRange: NSRange(location: 0, length: (raw as NSString).length),
            rawText: raw, indent: "", prefix: "",
            contentRange: NSRange(location: prefixLen, length: (latex as NSString).length)
        )
    }

    static func divider() -> EditorBlock {
        EditorBlock(
            id: UUID(), kind: .horizontalRule,
            sourceRange: NSRange(location: 0, length: 4),
            rawText: "---\n", indent: "", prefix: "---\n",
            contentRange: NSRange(location: 4, length: 0)
        )
    }

    private func rebuild(prefix newPrefix: String, content newContent: String, spans newSpans: [InlineSpan] = []) -> EditorBlock {
        var copy = self
        copy.prefix = newPrefix
        copy.cleanContent = newContent
        copy.spans = newSpans
        let serialized = newSpans.isEmpty ? newContent : InlineSerializer.serialize(content: newContent, spans: newSpans)
        copy.rawText = newPrefix + serialized + trailingNewline
        let prefixLen = (newPrefix as NSString).length
        copy.sourceRange = NSRange(location: sourceRange.location, length: (copy.rawText as NSString).length)
        copy.contentRange = NSRange(location: sourceRange.location + prefixLen, length: (serialized as NSString).length)
        return copy
    }

    private static func prefixString(for kind: EditorBlockKind, indent: String) -> String? {
        switch kind {
        case .heading(let level): return indent + String(repeating: "#", count: level) + " "
        case .bulletItem(let marker): return indent + marker + " "
        case .orderedItem(let number): return indent + "\(number). "
        case .checkboxItem(let checked, let marker):
            return indent + marker + " [\(checked ? "x" : " ")] "
        case .blockquote: return indent + "> "
        case .paragraph, .empty: return indent
        case .horizontalRule, .codeBlock, .table, .image, .callout, .toggle, .mathBlock: return nil
        }
    }
}

struct BlockDocument {
    var blocks: [EditorBlock]
    var source: String
}
