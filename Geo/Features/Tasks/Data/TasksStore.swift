import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "TasksStore")

@MainActor
final class TasksStore: ObservableObject {
    static let shared = TasksStore()

    @Published private(set) var tasks: [TaskItem] = []

    private var tasksById: [String: TaskItem] = [:]
    private var tasksByLinkedBlockId: [String: [String]] = [:]

    private let tasksDirectory: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.geo.tasksstore", qos: .userInitiated)
    private var fileWatcher: FileWatcherService?
    private let timestampLock = NSLock()
    private var recentWriteTimestamps: [String: Date] = [:]
    private let externalWriteGracePeriod: TimeInterval = 0.8

    init(baseURL: URL? = nil, loadAsync: Bool = true) {
        let baseURL = baseURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let directory = baseURL.appendingPathComponent("Geo/Tasks", isDirectory: true)
        tasksDirectory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if loadAsync {
            Task { [weak self] in
                await self?.loadTasksAsync()
                self?.startFileWatcher()
            }
        } else {
            loadTasks()
            startFileWatcher()
        }
    }

    private func startFileWatcher() {
        let watcher = FileWatcherService(url: tasksDirectory)
        watcher.onChange = { [weak self] urls in
            Task { @MainActor [weak self] in
                self?.handleExternalChanges(urls)
            }
        }
        watcher.start()
        fileWatcher = watcher
    }

    func task(for id: String) -> TaskItem? {
        tasksById[id]
    }

    func reload() {
        loadTasks()
    }

    func importTask(_ task: TaskItem) {
        guard tasksById[task.id] == nil else { return }
        tasks.append(task)
        indexInsert(task)
        persist(task)
    }

    func tasksLinked(to blockId: String) -> [TaskItem] {
        guard let ids = tasksByLinkedBlockId[blockId] else { return [] }
        return ids.compactMap { tasksById[$0] }.sorted { $0.createdAt < $1.createdAt }
    }

    func pendingTasksLinked(to blockId: String) -> [TaskItem] {
        guard let ids = tasksByLinkedBlockId[blockId] else { return [] }
        return ids.compactMap { tasksById[$0] }.filter { $0.status == .pending }.sorted { $0.createdAt < $1.createdAt }
    }

    func pendingTasks() -> [TaskItem] {
        tasks.filter { $0.status == .pending }
    }

    func completedTasks() -> [TaskItem] {
        tasks.filter { $0.status == .completed }
    }

    func dueTasks(at date: Date) -> [TaskItem] {
        tasks.filter { $0.status == .pending && $0.isDue(at: date) }
    }

    @discardableResult
    func createTask(
        title: String,
        notes: String = "",
        linkedBlockId: String? = nil,
        body: TaskBody,
        reminders: [Reminder] = [.atTime()],
        priority: TaskPriority = .unset,
        tagIds: [String] = [],
        estimatedMinutes: Int? = nil
    ) -> TaskItem? {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("TasksStore", operation: "create")
        defer { PerformanceTracker.shared.endStoreOperation("TasksStore", operation: "create", signpostID: spID, startTime: spStart) }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let maxOrder = pendingTasks().map(\.orderIndex).max() ?? -1
        let now = Date()
        let task = TaskItem(
            id: UUID().uuidString,
            title: trimmedTitle,
            notes: notes,
            linkedBlockId: linkedBlockId,
            status: .pending,
            priority: priority,
            tagIds: tagIds,
            orderIndex: maxOrder + 1,
            estimatedMinutes: estimatedMinutes,
            createdAt: now,
            modifiedAt: now,
            body: sanitize(body: body),
            reminders: reminders
        )
        tasks.append(task)
        indexInsert(task)
        persist(task)
        return task
    }

    func updateTask(
        id: String,
        title: String,
        notes: String,
        linkedBlockId: String?,
        body: TaskBody,
        reminders: [Reminder],
        status: TaskStatus,
        priority: TaskPriority = .unset,
        tagIds: [String] = [],
        estimatedMinutes: Int? = nil
    ) {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("TasksStore", operation: "update")
        defer { PerformanceTracker.shared.endStoreOperation("TasksStore", operation: "update", signpostID: spID, startTime: spStart) }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let existing = tasks[index]
        let newBody = preserveOccurrencesIfHabit(old: existing.body, new: body)
        let updated = TaskItem(
            id: existing.id,
            title: trimmedTitle,
            notes: notes,
            linkedBlockId: linkedBlockId,
            status: status,
            priority: priority,
            tagIds: tagIds,
            orderIndex: existing.orderIndex,
            estimatedMinutes: estimatedMinutes,
            createdAt: existing.createdAt,
            modifiedAt: Date(),
            body: sanitize(body: newBody),
            reminders: reminders
        )
        let previous = tasks[index]
        tasks[index] = updated
        indexReplace(previous: previous, updated: updated)
        persist(updated)
    }

    func tasksByKind(_ kind: TaskKind) -> [TaskItem] {
        tasks.filter { $0.kind == kind }
    }

    func tasksByPriority(_ priority: TaskPriority) -> [TaskItem] {
        tasks.filter { $0.priority == priority }
    }

    func deleteTask(id: String) {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("TasksStore", operation: "delete")
        defer { PerformanceTracker.shared.endStoreOperation("TasksStore", operation: "delete", signpostID: spID, startTime: spStart) }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks.remove(at: index)
        indexRemove(task)
        deletePersistedTask(task)
    }

    func moveTask(from source: IndexSet, to destination: Int) {
        var pending = pendingTasks().sorted { $0.orderIndex < $1.orderIndex }
        let validIndices = source.filter { $0 < pending.count }
        guard !validIndices.isEmpty else { return }
        let moving = validIndices.sorted().map { pending[$0] }
        for index in validIndices.sorted(by: >) {
            pending.remove(at: index)
        }
        let insertIndex = min(destination, pending.count)
        pending.insert(contentsOf: moving, at: insertIndex)
        updateOrderIndices(for: pending)
    }

    func reorderTask(_ taskId: String, before targetId: String) {
        var ordered = pendingTasks().sorted { $0.orderIndex < $1.orderIndex }
        guard let sourceIndex = ordered.firstIndex(where: { $0.id == taskId }),
              let targetIndex = ordered.firstIndex(where: { $0.id == targetId }) else { return }

        let moved = ordered.remove(at: sourceIndex)
        let insertIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        ordered.insert(moved, at: max(0, min(insertIndex, ordered.count)))
        updateOrderIndices(for: ordered)
    }

    func markReminderFired(id: String, reminderId: UUID) {
        updateTaskField(id: id) { task in
            guard let idx = task.reminders.firstIndex(where: { $0.id == reminderId }) else { return }
            task.reminders[idx].fired = true
        }
    }

    private func updateOrderIndices(for pending: [TaskItem]) {
        for (index, task) in pending.enumerated() {
            updateTaskField(id: task.id) { updated in
                updated.orderIndex = index
            }
        }
    }

    func replaceTask(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var updated = task
        updated.modifiedAt = Date()
        let previous = tasks[index]
        tasks[index] = updated
        indexReplace(previous: previous, updated: updated)
        persist(updated)
    }

    private func updateTaskField(id: String, apply: (inout TaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var updated = tasks[index]
        apply(&updated)
        updated.modifiedAt = Date()
        let previous = tasks[index]
        tasks[index] = updated
        indexReplace(previous: previous, updated: updated)
        persist(updated)
    }

    private func sanitize(body: TaskBody) -> TaskBody {
        switch body {
        case .event(let start, let end):
            return .event(start: start, end: max(end, start))
        case .habit(let rule, let tod, let occurrences):
            return .habit(rule: sanitizeRecurrence(rule), timeOfDay: tod, occurrences: occurrences)
        case .task, .milestone:
            return body
        }
    }

    private func preserveOccurrencesIfHabit(old: TaskBody, new: TaskBody) -> TaskBody {
        if case .habit(_, _, let oldOccs) = old, case .habit(let rule, let tod, let newOccs) = new {
            let merged = oldOccs + newOccs.filter { !oldOccs.contains($0) }
            return .habit(rule: rule, timeOfDay: tod, occurrences: merged)
        }
        return new
    }

    private func sanitizeRecurrence(_ rule: RecurrenceRule) -> RecurrenceRule {
        guard rule.type == .custom else { return rule }
        let frequency = rule.customFrequency ?? .daily
        let interval = max(1, rule.customInterval ?? 1)
        return .custom(every: interval, frequency: frequency)
    }

    private func loadTasksAsync() async {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("TasksStore", operation: "load")
        defer { PerformanceTracker.shared.endStoreOperation("TasksStore", operation: "load", signpostID: spID, startTime: spStart) }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: tasksDirectory, includingPropertiesForKeys: nil)
        } catch {
            logger.error("Failed to list tasks directory: \(error.localizedDescription)")
            return
        }
        let jsonURLs = urls.filter { $0.pathExtension == "json" }
        let loaded = await withTaskGroup(of: TaskItem?.self, returning: [TaskItem].self) { group in
            for url in jsonURLs {
                group.addTask {
                    do {
                        let data = try Data(contentsOf: url)
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        return try decoder.decode(TaskItem.self, from: data)
                    } catch {
                        logger.error("Failed to load task at \(url.lastPathComponent): \(error.localizedDescription)")
                        return nil
                    }
                }
            }
            var results: [TaskItem] = []
            for await item in group {
                if let item { results.append(item) }
            }
            return results
        }
        let sorted = loaded.sorted { $0.createdAt < $1.createdAt }
        await MainActor.run {
            self.tasks = sorted
            self.rebuildIndices()
        }
    }

    private func loadTasks() {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("TasksStore", operation: "load")
        defer { PerformanceTracker.shared.endStoreOperation("TasksStore", operation: "load", signpostID: spID, startTime: spStart) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: tasksDirectory, includingPropertiesForKeys: nil)
        } catch {
            logger.error("Failed to list tasks directory: \(error.localizedDescription)")
            return
        }
        let tasks = urls.compactMap { url -> TaskItem? in
            guard url.pathExtension == "json" else { return nil }
            do {
                let data = try Data(contentsOf: url)
                return try decoder.decode(TaskItem.self, from: data)
            } catch {
                logger.error("Failed to load task at \(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }
        self.tasks = tasks.sorted { $0.createdAt < $1.createdAt }
        rebuildIndices()
    }

    private func taskURL(for id: String) -> URL {
        tasksDirectory.appendingPathComponent("\(id).json")
    }

    private func persist(_ task: TaskItem) {
        timestampLock.lock()
        recentWriteTimestamps[task.id] = Date()
        timestampLock.unlock()
        let url = taskURL(for: task.id)
        queue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(task)
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error("Failed to persist task \(task.id): \(error.localizedDescription)")
            }
        }
    }

    private func deletePersistedTask(_ task: TaskItem) {
        timestampLock.lock()
        recentWriteTimestamps[task.id] = Date()
        timestampLock.unlock()
        let url = taskURL(for: task.id)
        queue.async {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                logger.error("Failed to delete persisted task \(task.id): \(error.localizedDescription)")
            }
        }
    }

    private func handleExternalChanges(_ urls: [URL]) {
        let now = Date()
        let jsonURLs = urls.filter { $0.pathExtension.lowercased() == "json" }
        guard !jsonURLs.isEmpty else { return }

        pruneWriteTimestamps()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var changed = false

        for url in jsonURLs {
            let taskId = url.deletingPathExtension().lastPathComponent
            timestampLock.lock()
            let lastWrite = recentWriteTimestamps[taskId]
            timestampLock.unlock()
            if let lastWrite, now.timeIntervalSince(lastWrite) < externalWriteGracePeriod {
                continue
            }

            if fileManager.fileExists(atPath: url.path) {
                guard let data = try? Data(contentsOf: url) else {
                    logger.error("Failed to read external task file: \(url.lastPathComponent)")
                    continue
                }
                guard let decoded = try? decoder.decode(TaskItem.self, from: data) else {
                    logger.error("Failed to decode external task file: \(url.lastPathComponent)")
                    continue
                }
                if let index = tasks.firstIndex(where: { $0.id == decoded.id }) {
                    tasks[index] = decoded
                } else {
                    tasks.append(decoded)
                }
                changed = true
            } else {
                if let index = tasks.firstIndex(where: { $0.id == taskId }) {
                    tasks.remove(at: index)
                    changed = true
                }
            }
        }

        if changed {
            tasks.sort { $0.createdAt < $1.createdAt }
            rebuildIndices()
        }
    }

    private func rebuildIndices() {
        tasksById.removeAll(keepingCapacity: true)
        tasksByLinkedBlockId.removeAll(keepingCapacity: true)
        for task in tasks {
            tasksById[task.id] = task
            if let blockId = task.linkedBlockId {
                tasksByLinkedBlockId[blockId, default: []].append(task.id)
            }
        }
    }

    private func indexInsert(_ task: TaskItem) {
        tasksById[task.id] = task
        if let blockId = task.linkedBlockId {
            tasksByLinkedBlockId[blockId, default: []].append(task.id)
        }
    }

    private func indexRemove(_ task: TaskItem) {
        tasksById.removeValue(forKey: task.id)
        if let blockId = task.linkedBlockId {
            removeLinkedId(task.id, from: blockId)
        }
    }

    private func indexReplace(previous: TaskItem, updated: TaskItem) {
        tasksById[updated.id] = updated
        if previous.linkedBlockId != updated.linkedBlockId {
            if let oldBlockId = previous.linkedBlockId {
                removeLinkedId(previous.id, from: oldBlockId)
            }
            if let newBlockId = updated.linkedBlockId {
                tasksByLinkedBlockId[newBlockId, default: []].append(updated.id)
            }
        }
    }

    private func removeLinkedId(_ taskId: String, from blockId: String) {
        guard var ids = tasksByLinkedBlockId[blockId] else { return }
        ids.removeAll { $0 == taskId }
        if ids.isEmpty {
            tasksByLinkedBlockId.removeValue(forKey: blockId)
        } else {
            tasksByLinkedBlockId[blockId] = ids
        }
    }

    private func pruneWriteTimestamps() {
        let cutoff = Date().addingTimeInterval(-externalWriteGracePeriod * 2)
        timestampLock.lock()
        recentWriteTimestamps = recentWriteTimestamps.filter { $0.value > cutoff }
        timestampLock.unlock()
    }
}
