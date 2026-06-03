import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "Phase0FrontmatterReinjection")

enum Phase0FrontmatterReinjectionError: Error {
    case emptyDatabase
}

final class Phase0FrontmatterReinjectionMigration: @unchecked Sendable {
    static let shared = Phase0FrontmatterReinjectionMigration()

    let enabledKey = "geo.migration.phase0.reinjectFrontmatter"
    let doneKey = "geo.migration.phase0.reinjectFrontmatter.done"

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private(set) var didRunThisLaunch = false

    init(userDefaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    func runIfEnabled(
        fileService: BlockFileService,
        database: DatabaseService,
        recordWrite: @escaping (String) -> Void
    ) async {
        guard userDefaults.bool(forKey: enabledKey) else { return }
        guard !userDefaults.bool(forKey: doneKey) else { return }
        do {
            try await migrate(fileService: fileService, database: database, recordWrite: recordWrite)
            userDefaults.set(true, forKey: doneKey)
            didRunThisLaunch = true
        } catch {
            logger.error("Phase 0 frontmatter re-injection failed: \(error.localizedDescription)")
        }
    }

    private func migrate(
        fileService: BlockFileService,
        database: DatabaseService,
        recordWrite: @escaping (String) -> Void
    ) async throws {
        let rows = try await database.fetchAllMetadataRows()
        guard !rows.isEmpty else {
            logger.fault("Phase 0 re-injection aborted: zero metadata rows (would demote every block to .user). No files written.")
            return
        }

        var metadataById: [String: (type: String, status: String?, layer: String, tagId: String?, isFullWidth: Bool)] = [:]
        for (id, row) in rows {
            let type: String = row["type"] ?? "fleeting"
            let status: String? = row["status"]
            let layer: String = row["layer"] ?? "user"
            let tagId: String? = row["tagId"]
            let isFullWidthInt: Int = row["isFullWidth"] ?? 0
            metadataById[id] = (type, status, layer, tagId, isFullWidthInt != 0)
        }

        let tagNamesById = loadTagNames(in: fileService.blocksDirectory)

        let blocksDirectory = fileService.blocksDirectory
        guard let enumerator = fileManager.enumerator(
            at: blocksDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            logger.error("Phase 0 re-injection: failed to enumerate blocks directory")
            return
        }

        var mdFiles: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            if fileService.relativeId(for: url).hasPrefix("Attachments/") { continue }
            mdFiles.append(url)
        }

        for url in mdFiles {
            let relativeId = fileService.relativeId(for: url)
            guard let meta = metadataById[relativeId] else {
                logger.info("Phase 0 re-injection: no metadata row for \(relativeId, privacy: .public); skipping")
                continue
            }
            guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let document = MarkdownConverter.shared.parse(original)
            let existingId = document.frontmatter["id"].flatMap { $0.isEmpty ? nil : $0 }
            let id = existingId ?? UUID().uuidString

            var tagNames: [String] = []
            if let tagId = meta.tagId, !tagId.isEmpty {
                if let name = tagNamesById[tagId] {
                    tagNames = [name]
                } else {
                    logger.info("Phase 0 re-injection: unresolved tagId \(tagId, privacy: .public); omitting tag for \(relativeId, privacy: .public)")
                }
            }

            let frontmatterBlock = FrontmatterBlockBuilder.block(
                id: id,
                type: meta.type,
                status: meta.status,
                layer: meta.layer,
                tags: tagNames,
                fullWidth: meta.isFullWidth
            )

            let rawBody = bodyAfterFrontmatter(original)
            let newContent = frontmatterBlock + rawBody

            recordWrite(relativeId)
            do {
                try newContent.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                logger.error("Phase 0 re-injection: failed to write \(relativeId, privacy: .public): \(error.localizedDescription)")
            }
        }
    }

    private func loadTagNames(in blocksDirectory: URL) -> [String: String] {
        let supportDir = blocksDirectory.deletingLastPathComponent()
        let tagsURL = supportDir.appendingPathComponent("tags.json")
        guard let data = try? Data(contentsOf: tagsURL),
              let tags = try? JSONDecoder().decode([Tag].self, from: data) else {
            return [:]
        }
        var map: [String: String] = [:]
        for tag in tags { map[tag.id] = tag.name }
        return map
    }

    private func bodyAfterFrontmatter(_ raw: String) -> String {
        var cursor = raw.startIndex
        func nextLine() -> (line: Substring, end: String.Index)? {
            guard cursor < raw.endIndex else { return nil }
            let start = cursor
            var i = cursor
            while i < raw.endIndex, raw[i] != "\n" { i = raw.index(after: i) }
            let line = raw[start..<i]
            let end = i < raw.endIndex ? raw.index(after: i) : raw.endIndex
            cursor = end
            return (line, end)
        }

        var sawOpen = false
        while let (line, end) = nextLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sawOpen {
                if trimmed.isEmpty { continue }
                guard trimmed == "---" else { return raw }
                sawOpen = true
                continue
            }
            if trimmed == "---" {
                return String(raw[end...])
            }
        }
        return raw
    }
}
