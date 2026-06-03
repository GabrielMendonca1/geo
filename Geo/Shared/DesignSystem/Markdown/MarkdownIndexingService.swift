import Foundation

struct MarkdownIndexResult: Equatable {
    let tags: [String]
    let openTaskCount: Int
    let completedTaskCount: Int
    let dayIds: [String]
    let frontmatterId: String?
}

extension Notification.Name {
    static let blockCheckboxesAllCompleted = Notification.Name("blockCheckboxesAllCompleted")
}

enum BlockCheckboxesAllCompletedUserInfoKey {
    static let blockId = "blockId"
    static let completedCount = "completedCount"
}

final class MarkdownIndexingService {
    static let shared = MarkdownIndexingService()

    private let tagRegex: NSRegularExpression
    private let openTaskRegex: NSRegularExpression
    private let completedTaskRegex: NSRegularExpression
    private let fencedCodeRegex: NSRegularExpression
    private let inlineCodeRegex: NSRegularExpression
    private let dayLinkRegex: NSRegularExpression

    private let markdownConverter: MarkdownConverter

    init(markdownConverter: MarkdownConverter = .shared) {
        self.markdownConverter = markdownConverter
        tagRegex = try! NSRegularExpression(pattern: "(?<!\\w)#([A-Za-z0-9_-]+)")
        openTaskRegex = try! NSRegularExpression(pattern: "(?m)^\\s*(?:[-*+]\\s+|\\d+\\.\\s+)\\[( )\\]\\s+")
        completedTaskRegex = try! NSRegularExpression(pattern: "(?m)^\\s*(?:[-*+]\\s+|\\d+\\.\\s+)\\[(x|X)\\]\\s+")
        fencedCodeRegex = try! NSRegularExpression(pattern: "```[^\\n]*\\n[\\s\\S]*?```", options: [])
        inlineCodeRegex = try! NSRegularExpression(pattern: "`[^`\\n]+`", options: [])
        dayLinkRegex = try! NSRegularExpression(pattern: "\\[\\[(\\d{4}-\\d{2}-\\d{2})(?:\\|[^\\]]*)?\\]\\]")
    }

    func extract(from markdown: String) -> MarkdownIndexResult {
        let parsed = markdownConverter.parse(markdown)
        return extract(from: parsed)
    }

    func extract(from document: MarkdownDocument) -> MarkdownIndexResult {
        let searchableBody = stripCodeBlocks(from: document.body)
        let bodyTags = extractTags(from: searchableBody)
        let frontmatterTags = extractFrontmatterTags(document.frontmatter)
        let tags = Array(Set(bodyTags + frontmatterTags)).sorted()
        let openTaskCount = countMatches(in: searchableBody, regex: openTaskRegex)
        let completedTaskCount = countMatches(in: searchableBody, regex: completedTaskRegex)
        let dayIds = extractDayIds(from: searchableBody)
        let frontmatterId = extractFrontmatterId(document.frontmatter)
        return MarkdownIndexResult(
            tags: tags,
            openTaskCount: openTaskCount,
            completedTaskCount: completedTaskCount,
            dayIds: dayIds,
            frontmatterId: frontmatterId
        )
    }

    private func stripCodeBlocks(from text: String) -> String {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var result = fencedCodeRegex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
        let resultRange = NSRange(location: 0, length: (result as NSString).length)
        result = inlineCodeRegex.stringByReplacingMatches(in: result, range: resultRange, withTemplate: "")
        return result
    }

    private func extractTags(from markdown: String) -> [String] {
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        let matches = tagRegex.matches(in: markdown, range: range)
        var tags: [String] = []
        tags.reserveCapacity(matches.count)
        for match in matches {
            guard match.numberOfRanges > 1,
                  let tagRange = Range(match.range(at: 1), in: markdown) else { continue }
            let tag = markdown[tagRange].lowercased()
            tags.append(tag)
        }
        return Array(Set(tags)).sorted()
    }

    private func countMatches(in markdown: String, regex: NSRegularExpression) -> Int {
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return regex.numberOfMatches(in: markdown, range: range)
    }

    func emitCheckboxCompletionIfNeeded(
        blockId: String,
        priorOpenCount: Int,
        newOpenCount: Int,
        newCompletedCount: Int,
        notificationCenter: NotificationCenter = .default
    ) {
        guard priorOpenCount > 0,
              newOpenCount == 0,
              newCompletedCount > 0 else {
            return
        }

        let userInfo: [String: Any] = [
            BlockCheckboxesAllCompletedUserInfoKey.blockId: blockId,
            BlockCheckboxesAllCompletedUserInfoKey.completedCount: newCompletedCount
        ]

        let post = {
            notificationCenter.post(
                name: .blockCheckboxesAllCompleted,
                object: nil,
                userInfo: userInfo
            )
        }

        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    func evaluateAndEmit(
        blockId: String,
        newResult: MarkdownIndexResult,
        database: DatabaseService = .shared,
        notificationCenter: NotificationCenter = .default
    ) async {
        let priorOpenCount: Int
        do {
            let existing = try await database.fetchBlocks(ids: [blockId])
            priorOpenCount = existing.first?.openTaskCount ?? 0
        } catch {
            priorOpenCount = 0
        }

        emitCheckboxCompletionIfNeeded(
            blockId: blockId,
            priorOpenCount: priorOpenCount,
            newOpenCount: newResult.openTaskCount,
            newCompletedCount: newResult.completedTaskCount,
            notificationCenter: notificationCenter
        )
    }
}
