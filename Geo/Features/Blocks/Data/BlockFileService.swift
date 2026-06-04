import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "BlockFileService")

final class BlockFileService {
    let blocksDirectory: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.geo.blockfileservice", qos: .userInitiated)
    private let markdownConverter: MarkdownConverter
    private let attachmentService: FileAttachmentService

    init(
        baseURL: URL? = nil,
        markdownConverter: MarkdownConverter = .shared,
        attachmentService: FileAttachmentService = FileAttachmentService()
    ) {
        self.markdownConverter = markdownConverter
        self.attachmentService = attachmentService
        let fm = FileManager.default
        let base = baseURL
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        self.blocksDirectory = base.appendingPathComponent("Geo/Blocks", isDirectory: true)
        try? fm.createDirectory(at: blocksDirectory, withIntermediateDirectories: true)
    }

    func blockURL(for filename: String) -> URL {
        blocksDirectory.appendingPathComponent(filename)
    }

    func folderURL(for relativeFolder: String) -> URL {
        let clean = relativeFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !clean.isEmpty else { return blocksDirectory }
        return blocksDirectory.appendingPathComponent(clean, isDirectory: true)
    }

    func createFolder(_ relativeFolder: String) throws {
        try fileManager.createDirectory(at: folderURL(for: relativeFolder), withIntermediateDirectories: true)
    }

    func listFolderPaths() -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: blocksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var folders: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let rel = relativeId(for: url)
            if rel == "Attachments" || rel.hasPrefix("Attachments/") { continue }
            if rel == "Daily" || rel.hasPrefix("Daily/") { continue }
            folders.append(rel)
        }
        return folders.sorted()
    }

    func uniqueURL(forTitle title: String, inFolder folder: String?) -> URL {
        let dir = folderURL(for: folder ?? "")
        let sanitized = sanitizeFilename(title)
        let name = sanitized.isEmpty ? "Block" : sanitized
        var candidate = name
        var attempt = 0
        while fileManager.fileExists(atPath: dir.appendingPathComponent(candidate).appendingPathExtension("md").path) {
            attempt += 1
            candidate = "\(name)-\(attempt)"
        }
        return dir.appendingPathComponent(candidate).appendingPathExtension("md")
    }

    func moveFile(from: URL, to: URL) throws {
        try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: from, to: to)
    }

    func relativeId(for url: URL) -> String {
        let basePath = blocksDirectory.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        if fullPath.hasPrefix(basePath + "/") {
            return String(fullPath.dropFirst(basePath.count + 1)).precomposedStringWithCanonicalMapping
        }
        return url.lastPathComponent.precomposedStringWithCanonicalMapping
    }

    func loadBlocksFromFiles(
        metadata: [String: BlocksStore.BlockMetadata],
        converter: MarkdownConverter
    ) async -> [BlocksStore.Block] {
        let resourceKeys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: blocksDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            logger.error("Failed to enumerate blocks directory")
            return []
        }

        var mdFiles: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            let rel = relativeId(for: url)
            if rel.hasPrefix("Attachments/") || rel.hasPrefix("Daily/") { continue }
            mdFiles.append(url)
        }

        let loaded = await withTaskGroup(of: BlocksStore.Block?.self, returning: [BlocksStore.Block].self) { group in
            for url in mdFiles {
                let blockId = relativeId(for: url)
                group.addTask {
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                    var blockMetadata = metadata[blockId] ?? BlocksStore.BlockMetadata()
                    let document = converter.parse(content)
                    let body = document.body
                    let title = Self.titleFromLines(body, allowTodoTitle: false)
                    blockMetadata.status = MarkdownConverter.normalizedStatus(document.frontmatter["status"])
                    blockMetadata.type = MarkdownConverter.normalizedType(document.frontmatter["type"])
                    if let fmLayer = MarkdownConverter.normalizedLayer(document.frontmatter["layer"]) {
                        blockMetadata.layer = fmLayer
                    }
                    if document.frontmatter["full_width"] != nil {
                        blockMetadata.isFullWidth = MarkdownConverter.normalizedFullWidth(document.frontmatter["full_width"])
                    }

                    let resourceValues = try? url.resourceValues(forKeys: resourceKeys)
                    let date = resourceValues?.creationDate ?? resourceValues?.contentModificationDate ?? .distantPast
                    let lastEdited = resourceValues?.contentModificationDate ?? date

                    return BlocksStore.Block(
                        id: blockId,
                        title: title,
                        date: date,
                        lastEdited: lastEdited,
                        markdown: content,
                        url: url,
                        metadata: blockMetadata
                    )
                }
            }
            var results: [BlocksStore.Block] = []
            for await block in group {
                if let block { results.append(block) }
            }
            return results
        }

        return loaded.sorted { $0.date > $1.date }
    }

    func writeMarkdownToDisk(_ markdown: String, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func writeMarkdownSync(_ markdown: String, url: URL) throws {
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    func removeMarkdownFromDisk(url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [fileManager] in
                do {
                    guard fileManager.fileExists(atPath: url.path) else {
                        continuation.resume(returning: ())
                        return
                    }
                    try fileManager.removeItem(at: url)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func deleteAttachmentsDirectory(for blockURL: URL) {
        attachmentService.deleteAttachmentsDirectory(for: blockURL)
    }

    nonisolated(unsafe) private static let attachmentRegex = try! NSRegularExpression(pattern: #"!\[.*?\]\((.+?)\)"#)

    static func extractAttachmentPaths(from markdown: String) -> Set<String> {
        let nsString = markdown as NSString
        let results = attachmentRegex.matches(in: markdown, range: NSRange(location: 0, length: nsString.length))
        var paths = Set<String>()
        for match in results {
            guard match.numberOfRanges > 1 else { continue }
            let pathRange = match.range(at: 1)
            guard pathRange.location != NSNotFound else { continue }
            let path = nsString.substring(with: pathRange)
            if path.hasPrefix("Attachments/") {
                let decoded = path.removingPercentEncoding ?? path
                paths.insert(decoded)
            }
        }
        return paths
    }

    func cleanupRemovedImages(oldMarkdown: String, newMarkdown: String) {
        let oldPaths = Self.extractAttachmentPaths(from: oldMarkdown)
        let newPaths = Self.extractAttachmentPaths(from: newMarkdown)
        let removed = oldPaths.subtracting(newPaths)
        for path in removed {
            attachmentService.deleteAttachment(relativePath: path, baseDirectory: blocksDirectory)
        }
    }

    func sanitizeFilename(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\*?\"<>|")
        return name
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func uniqueFilename(for base: String) -> String {
        let sanitized = sanitizeFilename(base)
        let name = sanitized.isEmpty ? "Block" : sanitized
        var candidate = name
        var attempt = 0
        while fileManager.fileExists(atPath: blocksDirectory.appendingPathComponent(candidate).appendingPathExtension("md").path) {
            attempt += 1
            candidate = "\(name)-\(attempt)"
        }
        return candidate
    }

    func titleFromMarkdown(_ markdown: String, fallback: String, allowTodoTitle: Bool) -> String {
        let document = markdownConverter.parse(markdown)
        return titleFromDocument(document, fallback: fallback, allowTodoTitle: allowTodoTitle)
    }

    func titleFromDocument(_ document: MarkdownDocument, fallback: String, allowTodoTitle: Bool) -> String {
        let body = document.body
        let lines = body.split(whereSeparator: \.isNewline)
        for line in lines {
            let stringLine = String(line)
            let trimmed = stringLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("#") {
                let stripped = trimmed
                    .drop(while: { $0 == "#" })
                    .drop(while: { $0 == " " })
                return String(stripped)
            }
            if trimmed.lowercased().hasPrefix("date:") {
                continue
            }
            let isCheckboxLine = trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")
            if isCheckboxLine && !allowTodoTitle {
                continue
            }
            return stringLine
        }
        return fallback
    }

    nonisolated static func titleFromLines(_ body: String, allowTodoTitle: Bool) -> String {
        let lines = body.split(whereSeparator: \.isNewline)
        for line in lines {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                let stripped = trimmed
                    .drop(while: { $0 == "#" })
                    .drop(while: { $0 == " " })
                return String(stripped)
            }
            if trimmed.lowercased().hasPrefix("date:") { continue }
            let isCheckboxLine = trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")
            if isCheckboxLine && !allowTodoTitle { continue }
            return String(line)
        }
        return ""
    }
}
