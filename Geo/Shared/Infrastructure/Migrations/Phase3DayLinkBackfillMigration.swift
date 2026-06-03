import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "Phase3DayLinkBackfill")

enum Phase3DayLinkBackfillError: Error {
    case emptyInput
}

final class Phase3DayLinkBackfillMigration: @unchecked Sendable {
    static let shared = Phase3DayLinkBackfillMigration()

    let enabledKey = "geo.migration.phase3.backfillDayLinks"
    let doneKey = "geo.migration.phase3.backfillDayLinks.done"

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private(set) var didRunThisLaunch = false

    init(userDefaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    func runIfEnabled(
        fileService: BlockFileService,
        recordWrite: @escaping (String) -> Void
    ) async {
        guard userDefaults.bool(forKey: enabledKey) else { return }
        guard !userDefaults.bool(forKey: doneKey) else { return }
        do {
            try migrate(fileService: fileService, recordWrite: recordWrite)
            userDefaults.set(true, forKey: doneKey)
            didRunThisLaunch = true
        } catch {
            logger.error("Phase 3 day-link backfill failed: \(error.localizedDescription)")
        }
    }

    private func migrate(
        fileService: BlockFileService,
        recordWrite: @escaping (String) -> Void
    ) throws {
        let supportDir = fileService.blocksDirectory.deletingLastPathComponent()
        let daysURL = supportDir.appendingPathComponent("days.json")

        guard let data = try? Data(contentsOf: daysURL),
              let days = try? JSONDecoder().decode([Day].self, from: data),
              !days.isEmpty else {
            logger.fault("Phase 3 day-link backfill aborted: days.json missing or empty. No files written; not marking done so it re-runs once data exists.")
            throw Phase3DayLinkBackfillError.emptyInput
        }

        let basenameMap = buildBasenameMap(fileService: fileService)

        var touchedDays: Set<String> = []
        for day in days {
            let dayId = day.id
            for bareId in day.blockIds {
                guard let relativeId = basenameMap[bareId] else {
                    logger.info("Phase 3 backfill: dropped unresolved/ambiguous blockId \(bareId, privacy: .public) for day \(dayId, privacy: .public)")
                    continue
                }
                let url = fileService.blocksDirectory.appendingPathComponent(relativeId)
                guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if MarkdownIndexingService.shared.extract(from: original).dayIds.contains(dayId) {
                    touchedDays.insert(dayId)
                    continue
                }
                let merged = DayLinkBody.inserting(dayId: dayId, into: original)
                recordWrite(relativeId)
                do {
                    try merged.write(to: url, atomically: true, encoding: .utf8)
                    touchedDays.insert(dayId)
                } catch {
                    logger.error("Phase 3 backfill: failed to write \(relativeId, privacy: .public): \(error.localizedDescription)")
                }
            }
        }

        let dailyDir = fileService.blocksDirectory.appendingPathComponent("Daily", isDirectory: true)
        for dayId in touchedDays {
            let noteURL = dailyDir.appendingPathComponent("\(dayId).md")
            guard !fileManager.fileExists(atPath: noteURL.path) else { continue }
            do {
                try fileManager.createDirectory(at: dailyDir, withIntermediateDirectories: true)
                try "# \(dayId)\n".write(to: noteURL, atomically: true, encoding: .utf8)
            } catch {
                logger.error("Phase 3 backfill: failed to create daily note \(dayId, privacy: .public): \(error.localizedDescription)")
            }
        }
    }

    private func buildBasenameMap(fileService: BlockFileService) -> [String: String] {
        guard let enumerator = fileManager.enumerator(
            at: fileService.blocksDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var candidates: [String: [String]] = [:]
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            let relativeId = fileService.relativeId(for: url)
            if relativeId.hasPrefix("Attachments/") || relativeId.hasPrefix("Daily/") { continue }
            let basename = url.lastPathComponent.precomposedStringWithCanonicalMapping
            candidates[basename, default: []].append(relativeId)
        }

        var map: [String: String] = [:]
        for (basename, ids) in candidates {
            if ids.count == 1 {
                map[basename] = ids[0]
            } else {
                logger.fault("Phase 3 backfill: ambiguous basename \(basename, privacy: .public) -> \(ids.joined(separator: ", "), privacy: .public); dropped (1:1 assertion failed).")
            }
        }
        return map
    }
}
