import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "FilesAreTruthMigration")

enum FilesAreTruthMigrationError: Error {
    case emptyDatabase
    case backupFailed
}

/// The single, deliberate entry point that completes the files-are-truth migration.
///
/// Default OFF. Nothing runs at launch unless the user flips
/// `geo.migration.filesAreTruth.enabled` to `true`. When enabled it:
///   1. aborts loudly if the SQLite index is empty (running would demote every block),
///   2. takes a whole-state backup of `~/Library/Application Support/Geo/` BEFORE touching files,
///   3. runs the four already-idempotent, done-flagged backfills in dependency order
///      (reinject -> layer -> tags -> day-links),
///   4. reloads + rebuilds the index after each phase that did work.
///
/// SQLite / days.json / tags.json stay in place as rebuildable caches and fallbacks; this runner
/// inlines properties into frontmatter, it does NOT drop the fallback columns (that hard cutover
/// is out of scope and remains gated/deferred).
final class FilesAreTruthMigrationRunner: @unchecked Sendable {
    static let shared = FilesAreTruthMigrationRunner()

    let enabledKey = "geo.migration.filesAreTruth.enabled"
    let doneKey = "geo.migration.filesAreTruth.done"

    private let userDefaults: UserDefaults
    private let backupService: BackupService
    private let phase0: Phase0FrontmatterReinjectionMigration
    private let phase1: Phase1LayerBackfillMigration
    private let phase2: Phase2TagBackfillMigration
    private let phase3: Phase3DayLinkBackfillMigration

    private(set) var didRunThisLaunch = false
    private(set) var didBackup = false

    init(
        userDefaults: UserDefaults = .standard,
        backupService: BackupService = .shared,
        phase0: Phase0FrontmatterReinjectionMigration = .shared,
        phase1: Phase1LayerBackfillMigration = .shared,
        phase2: Phase2TagBackfillMigration = .shared,
        phase3: Phase3DayLinkBackfillMigration = .shared
    ) {
        self.userDefaults = userDefaults
        self.backupService = backupService
        self.phase0 = phase0
        self.phase1 = phase1
        self.phase2 = phase2
        self.phase3 = phase3
    }

    struct Hooks {
        let reloadAndRebuild: @Sendable () async -> Void
        let refreshDays: @Sendable () async -> Void

        init(
            reloadAndRebuild: @escaping @Sendable () async -> Void = {},
            refreshDays: @escaping @Sendable () async -> Void = {}
        ) {
            self.reloadAndRebuild = reloadAndRebuild
            self.refreshDays = refreshDays
        }
    }

    func runIfEnabled(
        fileService: BlockFileService,
        database: DatabaseService,
        recordWrite: @escaping (String) -> Void,
        backupDirectory: URL,
        hooks: Hooks = Hooks()
    ) async {
        guard userDefaults.bool(forKey: enabledKey) else { return }
        guard !userDefaults.bool(forKey: doneKey) else { return }

        do {
            // (1) Abort-if-empty: running on an empty index would demote every block.
            let rows = (try? await database.fetchAllMetadataRows()) ?? []
            guard !rows.isEmpty else {
                logger.fault("files-are-truth migration aborted: zero metadata rows. No backup taken, no phases run, not marking done.")
                throw FilesAreTruthMigrationError.emptyDatabase
            }

            // (2) Whole-state backup BEFORE running. Abort the whole run if it fails.
            do {
                _ = try backupService.exportArchive(to: backupDirectory)
                didBackup = true
            } catch {
                logger.fault("files-are-truth migration aborted: pre-run backup failed: \(error.localizedDescription, privacy: .public)")
                throw FilesAreTruthMigrationError.backupFailed
            }

            // (3) Run the four backfills in dependency order, each idempotent + done-flagged.
            userDefaults.set(true, forKey: phase0.enabledKey)
            await phase0.runIfEnabled(fileService: fileService, database: database, recordWrite: recordWrite)
            if phase0.didRunThisLaunch { await hooks.reloadAndRebuild() }

            userDefaults.set(true, forKey: phase1.enabledKey)
            await phase1.runIfEnabled(fileService: fileService, database: database, recordWrite: recordWrite)
            if phase1.didRunThisLaunch { await hooks.reloadAndRebuild() }

            userDefaults.set(true, forKey: phase2.enabledKey)
            await phase2.runIfEnabled(fileService: fileService, database: database, recordWrite: recordWrite)
            if phase2.didRunThisLaunch { await hooks.reloadAndRebuild() }

            userDefaults.set(true, forKey: phase3.enabledKey)
            await phase3.runIfEnabled(fileService: fileService, recordWrite: recordWrite)
            if phase3.didRunThisLaunch {
                await hooks.reloadAndRebuild()
                await hooks.refreshDays()
            }

            userDefaults.set(true, forKey: doneKey)
            didRunThisLaunch = true
            logger.info("files-are-truth migration complete (backed up first; phases idempotent).")
        } catch {
            logger.error("files-are-truth migration did not complete: \(error.localizedDescription)")
        }
    }
}
