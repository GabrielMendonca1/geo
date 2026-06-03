import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "Phase2TagBackfill")

enum Phase2TagBackfillError: Error {
    case emptyDatabase
}

final class Phase2TagBackfillMigration: @unchecked Sendable {
    static let shared = Phase2TagBackfillMigration()

    let enabledKey = "geo.migration.phase2.backfillTags"
    let doneKey = "geo.migration.phase2.backfillTags.done"

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
            logger.error("Phase 2 tag backfill failed: \(error.localizedDescription)")
        }
    }

    private func migrate(
        fileService: BlockFileService,
        database: DatabaseService,
        recordWrite: @escaping (String) -> Void
    ) async throws {
        let rows = try await database.fetchAllMetadataRows()
        guard !rows.isEmpty else {
            logger.fault("Phase 2 tag backfill aborted: zero metadata rows. No files written; not marking done so it re-runs once the index is populated.")
            throw Phase2TagBackfillError.emptyDatabase
        }

        var tagIdById: [String: String] = [:]
        for (id, row) in rows {
            if let tagId: String = row["tagId"], !tagId.isEmpty {
                tagIdById[id] = tagId
            }
        }

        let tagNamesById = loadTagNames(in: fileService.blocksDirectory)

        let blocksDirectory = fileService.blocksDirectory
        guard let enumerator = fileManager.enumerator(
            at: blocksDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            logger.error("Phase 2 tag backfill: failed to enumerate blocks directory")
            return
        }

        var mdFiles: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            if fileService.relativeId(for: url).hasPrefix("Attachments/") { continue }
            mdFiles.append(url)
        }

        for url in mdFiles {
            let relativeId = fileService.relativeId(for: url)
            guard let tagId = tagIdById[relativeId] else { continue }
            guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let document = MarkdownConverter.shared.parse(original)
            if document.frontmatter["tags"] != nil { continue }

            guard let rawName = tagNamesById[tagId] else {
                logger.info("Phase 2 tag backfill: unresolved tagId \(tagId, privacy: .public); omitting tag for \(relativeId, privacy: .public)")
                continue
            }
            let canonical = TagStore.canonicalName(rawName)
            guard !canonical.isEmpty else { continue }

            let merged = FrontmatterEditor.upsert(in: original, values: ["tags": .array([.string(canonical)])])

            recordWrite(relativeId)
            do {
                try merged.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                logger.error("Phase 2 tag backfill: failed to write \(relativeId, privacy: .public): \(error.localizedDescription)")
            }
        }
    }

    private func loadTagNames(in blocksDirectory: URL) -> [String: String] {
        let supportDir = blocksDirectory.deletingLastPathComponent()
        let tagsURL = supportDir.appendingPathComponent("tags.json")
        guard let data = try? Data(contentsOf: tagsURL),
              let tags = try? TagStore.decodeTags(data) else {
            return [:]
        }
        var map: [String: String] = [:]
        for tag in tags { map[tag.id] = tag.name }
        return map
    }
}
