import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "TaskNotesMigration")

@MainActor
final class TaskNotesMigrationService {
    static let migrationKey = "tasks_notes_to_blocks_v1"
    static let migratedIdsKey = "tasks_notes_to_blocks_v1_migrated_ids"
    static let shortNoteThreshold = 200
    static let migratedNotesHeading = "## Notes (migrated)"

    private let tasksStore: TasksStore
    private let blocksStore: BlocksStore
    private let blocksRepository: any BlocksRepository
    private let defaults: UserDefaults

    init(
        tasksStore: TasksStore,
        blocksStore: BlocksStore,
        blocksRepository: (any BlocksRepository)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.tasksStore = tasksStore
        self.blocksStore = blocksStore
        self.blocksRepository = blocksRepository ?? BlocksStoreRepositoryAdapter(blocksStore: blocksStore)
        self.defaults = defaults
    }

    func runIfNeeded() async throws {
        guard !defaults.bool(forKey: Self.migrationKey) else { return }

        var failures = 0
        let snapshot = tasksStore.tasks
        var migratedIds = Set(defaults.stringArray(forKey: Self.migratedIdsKey) ?? [])

        for task in snapshot {
            if migratedIds.contains(task.id) { continue }
            do {
                try await migrate(task: task)
                migratedIds.insert(task.id)
                defaults.set(Array(migratedIds), forKey: Self.migratedIdsKey)
            } catch {
                failures += 1
                logger.error("Notes migration failed for task \(task.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if failures == 0 {
            defaults.set(true, forKey: Self.migrationKey)
            defaults.removeObject(forKey: Self.migratedIdsKey)
        }
    }

    private func migrate(task: TaskItem) async throws {
        let trimmed = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let isShort = task.notes.count <= Self.shortNoteThreshold
        if isShort && task.linkedBlockId == nil {
            return
        }

        if let blockId = task.linkedBlockId,
           let block = blocksStore.blocks.first(where: { $0.id == blockId }) {
            try await appendNotes(task: task, block: block)
        } else {
            try await createBlockAndLink(task: task)
        }
    }

    private func createBlockAndLink(task: TaskItem) async throws {
        let trimmedTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let blockTitle = trimmedTitle.isEmpty ? "Notes for \(task.title)" : trimmedTitle

        let newBlock: BlockEntity
        do {
            newBlock = try await blocksRepository.create(title: blockTitle, markdown: task.notes)
        } catch {
            throw TaskNotesMigrationError.blockCreationFailed
        }

        try persist(task: task, linkedBlockId: newBlock.id, notes: "")
    }

    private func appendNotes(task: TaskItem, block: BlocksStore.Block) async throws {
        let trimmedExisting = block.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmedExisting.isEmpty ? "" : trimmedExisting + "\n\n"
        let appended = prefix + "\(Self.migratedNotesHeading)\n\n" + task.notes

        do {
            try await blocksRepository.update(id: block.id, markdown: appended)
        } catch {
            throw TaskNotesMigrationError.blockUpdateFailed
        }

        try persist(task: task, linkedBlockId: task.linkedBlockId, notes: "")
    }

    private func persist(task: TaskItem, linkedBlockId: String?, notes: String) throws {
        guard tasksStore.task(for: task.id) != nil else {
            throw TaskNotesMigrationError.taskMissing
        }
        tasksStore.updateTask(
            id: task.id,
            title: task.title,
            notes: notes,
            linkedBlockId: linkedBlockId,
            startTime: task.startTime,
            endTime: task.endTime,
            reminders: task.reminders,
            recurringReminders: task.recurringReminders,
            recurrence: task.recurrence,
            smartReminder: task.smartReminder,
            status: task.status,
            kind: task.kind,
            priority: task.priority,
            tagIds: task.tagIds,
            parentId: task.parentId,
            estimatedMinutes: task.estimatedMinutes,
            context: task.context
        )
    }
}

enum TaskNotesMigrationError: Error, Equatable {
    case blockCreationFailed
    case blockUpdateFailed
    case taskMissing
}
