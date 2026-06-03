import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "Phase1LayerBackfill")

enum Phase1LayerBackfillError: Error {
    case emptyDatabase
}

final class Phase1LayerBackfillMigration: @unchecked Sendable {
    static let shared = Phase1LayerBackfillMigration()

    let enabledKey = "geo.migration.phase1.backfillLayer"
    let doneKey = "geo.migration.phase1.backfillLayer.done"

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
            logger.error("Phase 1 layer backfill failed: \(error.localizedDescription)")
        }
    }

    private func migrate(
        fileService: BlockFileService,
        database: DatabaseService,
        recordWrite: @escaping (String) -> Void
    ) async throws {
        let rows = try await database.fetchAllMetadataRows()
        guard !rows.isEmpty else {
            logger.fault("Phase 1 layer backfill aborted: zero metadata rows (would risk demoting blocks). No files written; not marking done so it re-runs once the index is populated.")
            throw Phase1LayerBackfillError.emptyDatabase
        }

        var layerById: [String: String] = [:]
        for (id, row) in rows {
            layerById[id] = row["layer"] ?? "user"
        }

        let blocksDirectory = fileService.blocksDirectory
        guard let enumerator = fileManager.enumerator(
            at: blocksDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            logger.error("Phase 1 layer backfill: failed to enumerate blocks directory")
            return
        }

        var mdFiles: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            if fileService.relativeId(for: url).hasPrefix("Attachments/") { continue }
            mdFiles.append(url)
        }

        for url in mdFiles {
            let relativeId = fileService.relativeId(for: url)
            guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let document = MarkdownConverter.shared.parse(original)
            if MarkdownConverter.normalizedLayer(document.frontmatter["layer"]) != nil { continue }

            let layerForId = layerById[relativeId] ?? BlockLayer.default.rawValue
            let merged = FrontmatterEditor.upsert(in: original, values: ["layer": .string(layerForId)])

            recordWrite(relativeId)
            do {
                try merged.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                logger.error("Phase 1 layer backfill: failed to write \(relativeId, privacy: .public): \(error.localizedDescription)")
            }
        }
    }
}
