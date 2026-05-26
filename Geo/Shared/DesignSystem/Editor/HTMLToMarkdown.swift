import Foundation

enum HTMLToMarkdown {
    static func convert(_ html: String) -> String? {
        var result = html

        result = decodeEntities(result)
        result = convertBlocks(result)
        result = convertInline(result)
        result = stripRemainingTags(result)
        result = cleanWhitespace(result)

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func decodeEntities(_ html: String) -> String {
        html.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func convertBlocks(_ html: String) -> String {
        var result = html

        for level in 1...6 {
            let prefix = String(repeating: "#", count: level)
            result = result.replacingOccurrences(
                of: "<h\(level)[^>]*>(.*?)</h\(level)>",
                with: "\n\(prefix) $1\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        result = result.replacingOccurrences(
            of: "<li[^>]*>(.*?)</li>",
            with: "- $1\n",
            options: [.regularExpression, .caseInsensitive]
        )

        result = result.replacingOccurrences(of: "</?[uo]l[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])

        result = result.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "<p[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "<div[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])

        result = result.replacingOccurrences(of: "<br[^>]*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])

        result = result.replacingOccurrences(
            of: "<blockquote[^>]*>(.*?)</blockquote>",
            with: "\n> $1\n",
            options: [.regularExpression, .caseInsensitive]
        )

        result = result.replacingOccurrences(of: "<hr[^>]*/?>", with: "\n---\n", options: [.regularExpression, .caseInsensitive])

        return result
    }

    private static func convertInline(_ html: String) -> String {
        var result = html

        result = result.replacingOccurrences(of: "<(b|strong)[^>]*>(.*?)</\\1>", with: "**$2**", options: [.regularExpression, .caseInsensitive])

        result = result.replacingOccurrences(of: "<(i|em)[^>]*>(.*?)</\\1>", with: "*$2*", options: [.regularExpression, .caseInsensitive])

        result = result.replacingOccurrences(of: "<(s|del|strike)[^>]*>(.*?)</\\1>", with: "~~$2~~", options: [.regularExpression, .caseInsensitive])

        result = result.replacingOccurrences(of: "<code[^>]*>(.*?)</code>", with: "`$1`", options: [.regularExpression, .caseInsensitive])

        result = result.replacingOccurrences(of: "<pre[^>]*><code[^>]*>(.*?)</code></pre>", with: "\n```\n$1\n```\n", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "<pre[^>]*>(.*?)</pre>", with: "\n```\n$1\n```\n", options: [.regularExpression, .caseInsensitive])

        result = result.replacingOccurrences(
            of: "<a[^>]*href=\"([^\"]*?)\"[^>]*>(.*?)</a>",
            with: "[$2]($1)",
            options: [.regularExpression, .caseInsensitive]
        )

        result = result.replacingOccurrences(
            of: "<img[^>]*src=\"([^\"]*?)\"[^>]*alt=\"([^\"]*?)\"[^>]*/?>",
            with: "![$2]($1)",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: "<img[^>]*src=\"([^\"]*?)\"[^>]*/?>",
            with: "![]($1)",
            options: [.regularExpression, .caseInsensitive]
        )

        return result
    }

    private static func stripRemainingTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func cleanWhitespace(_ text: String) -> String {
        var result = text
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        let lines = result.components(separatedBy: "\n")
        result = lines.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }.joined(separator: "\n")
        return result
    }
}
