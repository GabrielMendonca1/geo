import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "TasksViewModel")

struct TaskBlockOption: Identifiable, Equatable {
    let id: String
    let title: String

    init(block: BlockEntity) {
        id = block.id
        let trimmed = block.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed.isEmpty ? "Untitled Block" : trimmed
    }
}

struct PendingCompleteSuggestion: Identifiable, Equatable {
    let id: String
    let taskId: String
    let blockId: String
    let kind: TaskKind
    let title: String
}

@MainActor
final class TasksViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var showCompleted = true
    @Published var filterKind: TaskKind? = nil
    @Published var filterPriority: TaskPriority? = nil
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var linkedBlockCounts: [String: Int] = [:]
    @Published private(set) var linkedPendingBlockIds: Set<String> = []
    @Published private(set) var blockOptions: [TaskBlockOption] = []
    @Published private(set) var blocksVersion: Int = 0
    @Published private(set) var blockCheckboxesByTaskId: [String: [BlockCheckbox]] = [:]
    @Published private(set) var checkboxStateVersion: Int = 0
    @Published private(set) var pendingCompleteSuggestions: [PendingCompleteSuggestion] = []

    private var observeTasksTask: Task<Void, Never>?
    private var observeBlocksTask: Task<Void, Never>?
    private var tasksRepository: (any TasksRepository)?
    private var blocksRepository: (any BlocksRepository)?
    private var linkedBlocksById: [String: BlockEntity] = [:]
    private var isBound = false
    private var autoCompleteService: AutoCompleteSuggestionService?
    private var maybeCompleteObserver: NSObjectProtocol?
    private var suggestionAutoDismissTasks: [String: Task<Void, Never>] = [:]
    private static let maxVisibleSuggestions = 2

    deinit {
        observeTasksTask?.cancel()
        observeBlocksTask?.cancel()
        if let maybeCompleteObserver {
            NotificationCenter.default.removeObserver(maybeCompleteObserver)
        }
        for task in suggestionAutoDismissTasks.values {
            task.cancel()
        }
    }

    func bindIfNeeded(
        tasksRepository: any TasksRepository,
        blocksRepository: any BlocksRepository
    ) {
        guard !isBound else { return }
        bind(tasksRepository: tasksRepository, blocksRepository: blocksRepository)
    }

    func bind(
        tasksRepository: any TasksRepository,
        blocksRepository: any BlocksRepository
    ) {
        self.tasksRepository = tasksRepository
        self.blocksRepository = blocksRepository
        isBound = true

        observeTasksTask?.cancel()
        observeBlocksTask?.cancel()

        observeTasksTask = Task { [weak self] in
            for await observedTasks in tasksRepository.observe() {
                guard let self, !Task.isCancelled else { break }
                self.tasks = observedTasks
                self.refreshLinkedBlockCounts()
                await self.refreshCheckboxCache()
            }
        }

        observeBlocksTask = Task { [weak self] in
            for await observedBlocks in blocksRepository.observe() {
                guard let self, !Task.isCancelled else { break }
                self.linkedBlocksById = Dictionary(
                    observedBlocks.map { ($0.id, $0) },
                    uniquingKeysWith: { _, latest in latest }
                )
                self.blockOptions = observedBlocks
                    .map(TaskBlockOption.init(block:))
                    .sorted { lhs, rhs in
                        lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
                self.blocksVersion += 1
                await self.refreshCheckboxCache()
            }
        }

        startAutoCompleteSuggestionService(tasksRepository: tasksRepository)
        registerMaybeCompleteObserver()
    }

    private func startAutoCompleteSuggestionService(tasksRepository: any TasksRepository) {
        guard autoCompleteService == nil else { return }
        let service = AutoCompleteSuggestionService(tasksRepository: tasksRepository)
        service.start()
        autoCompleteService = service
    }

    private func registerMaybeCompleteObserver() {
        guard maybeCompleteObserver == nil else { return }
        maybeCompleteObserver = NotificationCenter.default.addObserver(
            forName: .taskMaybeComplete,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let taskId = userInfo[TaskMaybeCompleteUserInfoKey.taskId] as? String,
                  let blockId = userInfo[TaskMaybeCompleteUserInfoKey.blockId] as? String else {
                return
            }
            let kindRaw = userInfo[TaskMaybeCompleteUserInfoKey.kind] as? String
            let kind = kindRaw.flatMap(TaskKind.init(rawValue:)) ?? .task
            Task { @MainActor [weak self] in
                self?.enqueueSuggestion(taskId: taskId, blockId: blockId, kind: kind)
            }
        }
    }

    private func enqueueSuggestion(taskId: String, blockId: String, kind: TaskKind) {
        if pendingCompleteSuggestions.contains(where: { $0.taskId == taskId }) {
            return
        }
        guard let task = tasks.first(where: { $0.id == taskId }), task.status == .pending else {
            return
        }
        let suggestion = PendingCompleteSuggestion(
            id: UUID().uuidString,
            taskId: taskId,
            blockId: blockId,
            kind: kind,
            title: task.title
        )
        pendingCompleteSuggestions.append(suggestion)
        scheduleAutoDismiss(for: suggestion)
    }

    private func scheduleAutoDismiss(for suggestion: PendingCompleteSuggestion) {
        suggestionAutoDismissTasks[suggestion.id]?.cancel()
        let id = suggestion.id
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.dismissSuggestion(id: id)
            }
        }
        suggestionAutoDismissTasks[id] = task
    }

    func dismissSuggestion(id: String) {
        suggestionAutoDismissTasks[id]?.cancel()
        suggestionAutoDismissTasks.removeValue(forKey: id)
        pendingCompleteSuggestions.removeAll { $0.id == id }
    }

    func acceptSuggestion(id: String) async {
        guard let suggestion = pendingCompleteSuggestions.first(where: { $0.id == id }) else { return }
        dismissSuggestion(id: id)
        await completeTask(id: suggestion.taskId)
    }

    var visibleSuggestions: [PendingCompleteSuggestion] {
        Array(pendingCompleteSuggestions.prefix(Self.maxVisibleSuggestions))
    }

    func completeTask(id: String) async {
        guard let tasksRepository else { return }
        guard var task = tasks.first(where: { $0.id == id }) else { return }

        if case .habit(let rule, let timeOfDay, var occurrences) = task.body {
            let now = Date()
            let cal = Calendar.current
            if !occurrences.contains(where: { cal.isDate($0, inSameDayAs: now) }) {
                occurrences.append(now)
            }
            let nextTimeOfDay = rule.nextDate(after: timeOfDay)
            task.body = .habit(rule: rule, timeOfDay: nextTimeOfDay ?? timeOfDay, occurrences: occurrences)
            task.reminders = task.reminders.map { var r = $0; r.fired = false; return r }
            task.status = nextTimeOfDay == nil ? .completed : .pending
            task.modifiedAt = Date()
            do {
                try await tasksRepository.update(task)
            } catch {
                logger.error("Failed to advance habit \(id): \(error.localizedDescription)")
            }
        } else {
            await updateTask(id: id, status: .completed)
        }
    }

    func markTaskPending(id: String) async {
        await updateTask(id: id, status: .pending)
    }

    func deleteTask(id: String) async {
        guard let tasksRepository else { return }

        do {
            try await tasksRepository.delete(id: id)
        } catch {
            logger.error("Failed to delete task \(id): \(error.localizedDescription)")
        }
    }

    func task(withID id: String) async -> TaskItem? {
        if let localTask = tasks.first(where: { $0.id == id }) {
            return localTask
        }

        guard let tasksRepository else { return nil }

        do {
            return try await tasksRepository.list().first(where: { $0.id == id })
        } catch {
            return nil
        }
    }

    func linkedBlockCount(for blockId: String) -> Int {
        linkedBlockCounts[blockId, default: 0]
    }

    func searchedBlockOptions(matching query: String, include blockId: String? = nil) -> [TaskBlockOption] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: [TaskBlockOption]
        if trimmedQuery.isEmpty {
            matches = blockOptions
        } else {
            matches = blockOptions.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
        }

        guard
            let blockId,
            let selected = blockOptions.first(where: { $0.id == blockId }),
            !matches.contains(selected)
        else {
            return matches
        }

        return [selected] + matches
    }

    func linkedBlockTitle(for task: TaskItem) -> String? {
        guard let linkedId = task.linkedBlockId,
              let linkedBlock = linkedBlocksById[linkedId] else {
            return nil
        }
        return linkedBlock.displayTitle
    }

    func checkboxes(for task: TaskItem) -> [BlockCheckbox] {
        guard let blockId = task.linkedBlockId else { return [] }
        if let cached = blockCheckboxesByTaskId[task.id] { return cached }
        return blockCheckboxesByTaskId[blockId] ?? []
    }

    func hasLinkedBlock(_ task: TaskItem) -> Bool {
        guard let linkedId = task.linkedBlockId else { return false }
        return linkedBlocksById[linkedId] != nil
    }

    func toggleCheckbox(in blockId: String, lineNumber: Int, taskId: String) async {
        guard let blocksRepository else { return }

        if var current = blockCheckboxesByTaskId[taskId],
           let idx = current.firstIndex(where: { $0.lineNumber == lineNumber }) {
            let cb = current[idx]
            current[idx] = BlockCheckbox(text: cb.text, checked: !cb.checked, lineNumber: cb.lineNumber)
            blockCheckboxesByTaskId[taskId] = current
            checkboxStateVersion &+= 1
        }

        do {
            try await blocksRepository.toggleCheckbox(in: blockId, lineNumber: lineNumber)
        } catch {
            logger.error("Failed to toggle checkbox in block \(blockId) line \(lineNumber): \(error.localizedDescription)")
        }

        await refreshCheckboxCache(for: [taskId])
    }

    private func refreshCheckboxCache() async {
        let visibleTaskIds = visibleCheckboxTaskIds()
        await refreshCheckboxCache(for: visibleTaskIds)
    }

    private func visibleCheckboxTaskIds() -> [String] {
        tasks
            .filter { $0.status == .pending && $0.linkedBlockId != nil }
            .map(\.id)
    }

    private func refreshCheckboxCache(for taskIds: [String]) async {
        guard let blocksRepository else { return }
        guard !taskIds.isEmpty else {
            if !blockCheckboxesByTaskId.isEmpty {
                blockCheckboxesByTaskId.removeAll()
                checkboxStateVersion &+= 1
            }
            return
        }

        let pairs: [(String, String)] = taskIds.compactMap { taskId in
            guard let task = tasks.first(where: { $0.id == taskId }),
                  let blockId = task.linkedBlockId else { return nil }
            return (taskId, blockId)
        }

        var fetched: [String: [BlockCheckbox]] = [:]
        var blockCache: [String: [BlockCheckbox]] = [:]
        for (taskId, blockId) in pairs {
            if let existing = blockCache[blockId] {
                fetched[taskId] = existing
            } else {
                let result = await blocksRepository.checkboxes(in: blockId)
                blockCache[blockId] = result
                fetched[taskId] = result
            }
        }

        let validTaskIds = Set(visibleCheckboxTaskIds())
        var merged = blockCheckboxesByTaskId.filter { validTaskIds.contains($0.key) }
        for (taskId, list) in fetched {
            merged[taskId] = list
        }

        if merged != blockCheckboxesByTaskId {
            blockCheckboxesByTaskId = merged
            checkboxStateVersion &+= 1
        }
    }

    var filteredTasks: [TaskItem] {
        var result = tasks
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        if let filterKind {
            result = result.filter { $0.kind == filterKind }
        }
        if let filterPriority {
            result = result.filter { $0.priority == filterPriority }
        }
        return result
    }

    var pendingTasks: [TaskItem] {
        filteredTasks
            .filter { $0.status == .pending }
            .sorted(by: Self.pendingSort)
    }

    var pastDueTasks: [TaskItem] {
        pendingTasks.filter(\.isOverdue)
    }

    var regularPendingTasks: [TaskItem] {
        pendingTasks.filter { !$0.isOverdue }
    }

    var availableContexts: [String] {
        Array(Set(tasks.compactMap(\.context))).sorted()
    }

    var habits: [TaskItem] {
        pendingTasks.filter { $0.kind == .habit }
    }

    func subtasks(of taskId: String) -> [TaskItem] {
        tasks.filter { $0.parentId == taskId }
    }

    var completedTasks: [TaskItem] {
        filteredTasks
            .filter { $0.status == .completed }
            .sorted(by: Self.completedSort)
    }

    private static func pendingSort(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.priority.sortOrder != rhs.priority.sortOrder {
            return lhs.priority.sortOrder < rhs.priority.sortOrder
        }

        if lhs.startTime != rhs.startTime {
            return lhs.startTime < rhs.startTime
        }

        if lhs.orderIndex != rhs.orderIndex {
            return lhs.orderIndex < rhs.orderIndex
        }

        return lhs.id < rhs.id
    }

    private static func completedSort(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }

        if lhs.startTime != rhs.startTime {
            return lhs.startTime > rhs.startTime
        }

        return lhs.id > rhs.id
    }

    private func updateTask(id: String, status: TaskStatus) async {
        guard let tasksRepository else { return }
        guard var task = tasks.first(where: { $0.id == id }) else { return }

        task.status = status
        task.modifiedAt = Date()

        do {
            try await tasksRepository.update(task)
        } catch {
            logger.error("Failed to update task \(id) status: \(error.localizedDescription)")
        }
    }

    private func refreshLinkedBlockCounts() {
        var counts: [String: Int] = [:]
        var pendingIds: Set<String> = []
        for task in tasks where task.status == .pending {
            guard let blockId = task.linkedBlockId else { continue }
            counts[blockId, default: 0] += 1
            pendingIds.insert(blockId)
        }
        linkedBlockCounts = counts
        linkedPendingBlockIds = pendingIds
    }
}
