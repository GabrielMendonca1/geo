import Foundation

struct BlockEntity: Identifiable, Hashable, Sendable {
    struct Metadata: Codable, Hashable, Sendable {
        var dayId: String?
        var tagId: String?
        var tagName: String?
        var isFullWidth: Bool
        var status: String?
        var type: BlockType
        var layer: BlockLayer

        init(
            dayId: String? = nil,
            tagId: String? = nil,
            tagName: String? = nil,
            isFullWidth: Bool = false,
            status: String? = nil,
            type: BlockType = .fleeting,
            layer: BlockLayer = .default
        ) {
            self.dayId = dayId
            self.tagId = tagId
            self.tagName = tagName
            self.isFullWidth = isFullWidth
            self.status = status
            self.type = type
            self.layer = layer
        }
    }

    let id: String
    let title: String
    let date: Date
    let lastEdited: Date
    let markdown: String
    let url: URL
    let tagId: String?
    let metadata: Metadata

    var tagName: String? { metadata.tagName }

    init(
        id: String,
        title: String,
        date: Date,
        lastEdited: Date,
        markdown: String,
        url: URL,
        tagId: String?,
        metadata: Metadata
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.lastEdited = lastEdited
        self.markdown = markdown
        self.url = url
        self.tagId = tagId
        self.metadata = metadata
    }

    var displayTitle: String {
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Untitled" }
        var text = raw
        if text.hasPrefix("#") {
            text = String(text.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))
        }
        text = Self.stripInlineMarkdown(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripInlineMarkdown(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"\!\[([^\]]*)\]\([^\)]+\)"#, "$1"),
            (#"\[([^\]]+)\]\([^\)]+\)"#, "$1"),
            (#"\*\*\*(.+?)\*\*\*"#, "$1"),
            (#"___(.+?)___"#, "$1"),
            (#"\*\*(.+?)\*\*"#, "$1"),
            (#"__(.+?)__"#, "$1"),
            (#"\*(.+?)\*"#, "$1"),
            (#"_(.+?)_"#, "$1"),
            (#"~~(.+?)~~"#, "$1"),
            (#"`(.+?)`"#, "$1"),
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
            }
        }
        return result
    }
}
