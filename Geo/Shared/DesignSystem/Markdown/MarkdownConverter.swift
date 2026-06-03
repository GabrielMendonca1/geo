import Foundation

struct MarkdownDocument: Equatable {
    let frontmatter: [String: String]
    let body: String
}

final class MarkdownConverter {
    static let shared = MarkdownConverter()

    func status(in markdown: String) -> String? {
        let document = parse(markdown)
        return Self.normalizedStatus(document.frontmatter["status"])
    }

    static func normalizedStatus(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    func type(in markdown: String) -> BlockType {
        let document = parse(markdown)
        return Self.normalizedType(document.frontmatter["type"])
    }

    static func normalizedType(_ raw: String?) -> BlockType {
        guard let raw else { return .fleeting }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        return BlockType(rawValue: trimmed) ?? .fleeting
    }

    func layer(in markdown: String) -> BlockLayer? {
        let document = parse(markdown)
        return Self.normalizedLayer(document.frontmatter["layer"])
    }

    static func normalizedLayer(_ raw: String?) -> BlockLayer? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .precomposedStringWithCanonicalMapping
            .lowercased()
        return trimmed.isEmpty ? nil : BlockLayer(rawValue: trimmed)
    }

    static func frontmatterVersion(_ raw: String?) -> Int {
        guard let raw else { return 0 }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return Int(trimmed) ?? 0
    }

    func frontmatterVersion(in markdown: String) -> Int {
        let document = parse(markdown)
        return Self.frontmatterVersion(document.frontmatter["frontmatter_version"])
    }

    static func normalizedFullWidth(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        return trimmed == "true" || trimmed == "yes"
    }

    func fullWidth(in markdown: String) -> Bool {
        let document = parse(markdown)
        return Self.normalizedFullWidth(document.frontmatter["full_width"])
    }

    func parse(_ markdown: String) -> MarkdownDocument {
        let lines = markdown.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index += 1
        }
        guard index < lines.count,
              lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return MarkdownDocument(frontmatter: [:], body: markdown)
        }
        index += 1
        var frontmatterLines: [String] = []
        var foundClosingDelimiter = false
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" {
                index += 1
                foundClosingDelimiter = true
                break
            }
            frontmatterLines.append(lines[index])
            index += 1
        }
        guard foundClosingDelimiter else {
            return MarkdownDocument(frontmatter: [:], body: markdown)
        }
        var frontmatter: [String: String] = [:]
        for line in frontmatterLines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard !parts.isEmpty else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            if !key.isEmpty {
                if FrontmatterYAML.parseInlineList(rawValue) != nil {
                    frontmatter[key] = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    frontmatter[key] = FrontmatterYAML.parseScalar(rawValue)
                }
            }
        }
        let body = lines.dropFirst(index).joined(separator: "\n")
        return MarkdownDocument(frontmatter: frontmatter, body: body)
    }

    func frontmatterList(_ document: MarkdownDocument, key: String) -> [String] {
        document.frontmatter[key].flatMap { FrontmatterYAML.parseInlineList($0) } ?? []
    }

}

enum FrontmatterYAML {
    private static let indicatorChars: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]
    private static let reservedWords: Set<String> = ["true", "false", "null", "yes", "no", "~"]

    static func needsQuoting(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s != s.trimmingCharacters(in: .whitespaces) { return true }
        for ch in s where ch == ":" || ch == "#" || ch == "[" || ch == "]" || ch == "{" || ch == "}" || ch == "," || ch == "\"" || ch == "'" || ch == "\n" {
            return true
        }
        if let first = s.first, indicatorChars.contains(first) { return true }
        if reservedWords.contains(s.lowercased()) { return true }
        if Int(s) != nil { return true }
        if Double(s) != nil { return true }
        return false
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }

    static func emitScalar(_ s: String) -> String {
        if parseInlineList(s) != nil { return s }
        return needsQuoting(s) ? quote(s) : s
    }

    static let integerKeys: Set<String> = ["frontmatter_version"]
    static let booleanKeys: Set<String> = ["full_width"]

    static func emitScalar(key: String, value: String) -> String {
        if integerKeys.contains(key), Int(value) != nil { return value }
        if booleanKeys.contains(key) {
            let lowered = value.trimmingCharacters(in: .whitespaces).lowercased()
            if lowered == "true" || lowered == "false" { return lowered }
        }
        return emitScalar(value)
    }

    static func emitInlineList(_ items: [String]) -> String {
        "[" + items.map { needsQuoting($0) ? quote($0) : $0 }.joined(separator: ", ") + "]"
    }

    static func parseScalar(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" {
            return unescapeDouble(String(trimmed.dropFirst().dropLast()))
        }
        if trimmed.count >= 2, trimmed.first == "'", trimmed.last == "'" {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return trimmed
    }

    static func parseInlineList(_ raw: String) -> [String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        var elements: [String] = []
        var current = ""
        var inDouble = false
        var inSingle = false
        var escaped = false
        for ch in inner {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if inDouble && ch == "\\" {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                current.append(ch)
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
                current.append(ch)
                continue
            }
            if ch == "," && !inDouble && !inSingle {
                elements.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        elements.append(current)
        let parsed = elements.map { parseScalar($0) }
        var result = parsed
        while result.first?.isEmpty == true { result.removeFirst() }
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    private static func unescapeDouble(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if escaped {
                switch ch {
                case "n": out += "\n"
                case "t": out += "\t"
                case "r": out += "\r"
                case "\\": out += "\\"
                case "\"": out += "\""
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
