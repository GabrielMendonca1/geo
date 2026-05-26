import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "TaskMigration")

final class TaskMigrationService {
    static let shared = TaskMigrationService()

    private let migrationKey = "tasksMigrationCompleted"
    private let fileManager = FileManager.default

    func migrateIfNeeded(tasksRepository: any TasksRepository) async {
        if UserDefaults.standard.bool(forKey: migrationKey) {
            return
        }

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let blocksDirectory = baseURL.appendingPathComponent("Geo/Blocks", isDirectory: true)
        let metadataURL = blocksDirectory.appendingPathComponent(".blocks-metadata.json")

        guard let data = try? Data(contentsOf: metadataURL) else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyMetadata = (try? decoder.decode([String: LegacyBlockMetadata].self, from: data)) ?? [:]
        guard !legacyMetadata.isEmpty else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        var updatedMetadata: [String: BlocksStore.BlockMetadata] = [:]

        for (blockId, metadata) in legacyMetadata {
            if metadata.isTask == true {
                await migrateTaskBlock(blockId: blockId, metadata: metadata, blocksDirectory: blocksDirectory, tasksRepository: tasksRepository)
            } else {
                updatedMetadata[blockId] = BlocksStore.BlockMetadata(dayId: metadata.dayId, tagId: metadata.tagId)
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let updatedData = try encoder.encode(updatedMetadata)
            try updatedData.write(to: metadataURL, options: .atomic)
        } catch {
            logger.error("Failed to write updated metadata after task migration: \(error.localizedDescription)")
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    private func migrateTaskBlock(blockId: String, metadata: LegacyBlockMetadata, blocksDirectory: URL, tasksRepository: any TasksRepository) async {
        let url = blocksDirectory.appendingPathComponent(blockId)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parsed = parseTaskContent(from: content)

        let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let createdAt = resourceValues?.creationDate ?? Date()
        let modifiedAt = resourceValues?.contentModificationDate ?? createdAt

        let task = TaskItem(
            id: blockId,
            title: parsed.title,
            notes: parsed.notes,
            linkedBlockId: metadata.linkedBlockId,
            status: metadata.status ?? .pending,
            startTime: metadata.startTime ?? createdAt,
            endTime: metadata.endTime,
            reminders: metadata.reminders ?? [.atTime],
            recurringReminders: metadata.recurringReminders ?? [],
            recurrence: metadata.recurrence ?? .never,
            firedReminders: metadata.firedReminders ?? [],
            orderIndex: metadata.orderIndex ?? 0,
            smartReminder: metadata.smartReminder ?? false,
            snoozedUntil: metadata.snoozedUntil,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )

        do {
            try await tasksRepository.importTask(task)
        } catch {
            logger.error("Failed to import migrated task \(blockId): \(error.localizedDescription)")
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.error("Failed to remove migrated block file \(blockId): \(error.localizedDescription)")
        }
    }

    private func parseTaskContent(from content: String) -> (title: String, notes: String) {
        let body = MarkdownConverter.shared.parse(content).body
        var lines = body.components(separatedBy: .newlines)
        var title = ""
        if let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                title = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                lines.removeFirst()
            }
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        let notes = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (title.isEmpty ? "Untitled Task" : title, notes)
    }
}

private struct LegacyBlockMetadata: Codable {
    var dayId: String?
    var tagId: String?
    var linkedBlockId: String?
    var isTask: Bool?
    var status: TaskStatus?
    var startTime: Date?
    var endTime: Date?
    var snoozedUntil: Date?
    var reminders: [ReminderOffset]?
    var recurringReminders: [RecurringReminder]?
    var recurrence: RecurrenceRule?
    var firedReminders: [ReminderOffset]?
    var orderIndex: Int?
    var smartReminder: Bool?
}
