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
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !key.isEmpty {
                frontmatter[key] = value
            }
        }
        let body = lines.dropFirst(index).joined(separator: "\n")
        return MarkdownDocument(frontmatter: frontmatter, body: body)
    }

}
