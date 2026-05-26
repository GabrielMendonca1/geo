import Foundation
import Combine

extension Notification.Name {
    static let checkboxToggledInEditor = Notification.Name("checkboxToggledInEditor")
}

enum CheckboxToggledUserInfoKey {
    static let blockId = "blockId"
    static let lineNumber = "lineNumber"
    static let checked = "checked"
}

enum CheckboxPromotionError: Error, Equatable {
    case blockNotFound
    case lineNotFound
    case notACheckbox
    case alreadyPromoted
    case persistenceFailed
}

@MainActor
final class CheckboxPromotionManager {
    let tasksStore: TasksStore
    let blocksStore: BlocksStore
    let blocksRepository: any BlocksRepository

    static let markerRegex = try! NSRegularExpression(pattern: #"<!--\s*task:([0-9A-Fa-f-]{8,36})\s*-->"#)

    private var cancellables: Set<AnyCancellable> = []
    private var notificationToken: NSObjectProtocol?
    private var previousTaskStatus: [String: TaskStatus] = [:]
    private var previousTaskBlockIds: [String: String?] = [:]
    private var isSyncingFromTaskChange = false

    init(tasksStore: TasksStore, blocksStore: BlocksStore, blocksRepository: any BlocksRepository) {
        self.tasksStore = tasksStore
        self.blocksStore = blocksStore
        self.blocksRepository = blocksRepository
        seedTaskSnapshot(tasks: tasksStore.tasks)
        subscribeToTasks()
        subscribeToNotifications()
    }

    deinit {
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
        }
    }

    static func extractTaskId(from line: String) -> String? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = markerRegex.firstMatch(in: line, range: range), m.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }

    static func removeMarker(from line: String) -> String {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        let stripped = markerRegex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        return stripped.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
    }

    static func insertMarker(taskId: String, into line: String) -> String {
        let cleaned = removeMarker(from: line)
        let trailing = cleaned.hasSuffix(" ") ? "" : " "
        return cleaned + trailing + "<!-- task:\(taskId) -->"
    }

    @discardableResult
    func promoteCheckbox(blockId: String, lineNumber: Int) async throws -> TaskItem {
        guard let block = blocksStore.blocks.first(where: { $0.id == blockId }) else {
            throw CheckboxPromotionError.blockNotFound
        }
        guard var lines = blocksStore.splitLines(blockId: blockId) else {
            throw CheckboxPromotionError.blockNotFound
        }
        let index = lineNumber - 1
        guard index >= 0, index < lines.count else {
            throw CheckboxPromotionError.lineNotFound
        }
        let line = lines[index]
        guard let match = blocksStore.checkboxMatch(line: line) else {
            throw CheckboxPromotionError.notACheckbox
        }
        if let existingTaskId = Self.extractTaskId(from: line),
           tasksStore.task(for: existingTaskId) != nil {
            throw CheckboxPromotionError.alreadyPromoted
        }

        let taskTitle = Self.removeMarker(from: match.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskTitle.isEmpty else {
            throw CheckboxPromotionError.notACheckbox
        }

        let parentMilestoneId = tasksStore.tasks.first(where: {
            $0.kind == .milestone && $0.linkedBlockId == blockId && $0.status == .pending
        })?.id

        guard let created = tasksStore.createTask(
            title: taskTitle,
            linkedBlockId: blockId,
            startTime: Date(),
            kind: .task,
            parentId: parentMilestoneId
        ) else {
            throw CheckboxPromotionError.persistenceFailed
        }

        let newLine = Self.insertMarker(taskId: created.id, into: line)
        lines[index] = newLine
        let newMarkdown = lines.joined(separator: "\n")
        let ok: Bool
        do {
            try await blocksRepository.update(id: block.id, markdown: newMarkdown)
            ok = true
        } catch {
            ok = false
        }
        if !ok {
            tasksStore.deleteTask(id: created.id)
            throw CheckboxPromotionError.persistenceFailed
        }

        if match.checked, created.status != .completed {
            applyTaskStatus(taskId: created.id, status: .completed)
        }

        previousTaskStatus[created.id] = match.checked ? .completed : .pending
        previousTaskBlockIds[created.id] = blockId

        return created
    }

    func syncTaskStatus(forBlockId blockId: String, lineNumber: Int, checked: Bool) async {
        guard let lines = blocksStore.splitLines(blockId: blockId) else { return }
        let index = lineNumber - 1
        guard index >= 0, index < lines.count else { return }
        guard let taskId = Self.extractTaskId(from: lines[index]) else { return }
        guard let task = tasksStore.task(for: taskId) else { return }
        let desired: TaskStatus = checked ? .completed : .pending
        guard task.status != desired else { return }
        applyTaskStatus(taskId: taskId, status: desired)
    }

    func syncCheckboxStatus(forTaskId taskId: String) async {
        guard let task = tasksStore.task(for: taskId) else { return }
        guard let blockId = task.linkedBlockId else { return }
        guard let block = blocksStore.blocks.first(where: { $0.id == blockId }) else { return }
        guard var lines = blocksStore.splitLines(blockId: blockId) else { return }
        var didMutate = false
        for i in 0..<lines.count {
            guard let lineTaskId = Self.extractTaskId(from: lines[i]), lineTaskId == taskId else { continue }
            let desiredChecked = task.status == .completed
            if let updated = blocksStore.setCheckboxChecked(line: lines[i], checked: desiredChecked),
               updated != lines[i] {
                lines[i] = updated
                didMutate = true
            }
            break
        }
        guard didMutate else { return }
        let newMarkdown = lines.joined(separator: "\n")
        isSyncingFromTaskChange = true
        try? await blocksRepository.update(id: block.id, markdown: newMarkdown)
        isSyncingFromTaskChange = false
    }

    private func subscribeToTasks() {
        tasksStore.$tasks
            .receive(on: RunLoop.main)
            .sink { [weak self] updatedTasks in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleTasksUpdate(updatedTasks)
                }
            }
            .store(in: &cancellables)
    }

    private func subscribeToNotifications() {
        notificationToken = NotificationCenter.default.addObserver(
            forName: .checkboxToggledInEditor,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let blockId = note.userInfo?[CheckboxToggledUserInfoKey.blockId] as? String,
                  let lineNumber = note.userInfo?[CheckboxToggledUserInfoKey.lineNumber] as? Int,
                  let checked = note.userInfo?[CheckboxToggledUserInfoKey.checked] as? Bool else {
                return
            }
            Task { @MainActor in
                await self.syncTaskStatus(forBlockId: blockId, lineNumber: lineNumber, checked: checked)
            }
        }
    }

    private func seedTaskSnapshot(tasks: [TaskItem]) {
        for task in tasks {
            previousTaskStatus[task.id] = task.status
            previousTaskBlockIds[task.id] = task.linkedBlockId
        }
    }

    private func handleTasksUpdate(_ updatedTasks: [TaskItem]) async {
        guard !isSyncingFromTaskChange else {
            seedTaskSnapshot(tasks: updatedTasks)
            return
        }
        var statusFlipped: [String] = []
        for task in updatedTasks {
            let prior = previousTaskStatus[task.id]
            if prior != nil, prior != task.status, task.linkedBlockId != nil {
                statusFlipped.append(task.id)
            }
        }
        seedTaskSnapshot(tasks: updatedTasks)
        for taskId in statusFlipped {
            await syncCheckboxStatus(forTaskId: taskId)
        }
    }

    private func applyTaskStatus(taskId: String, status: TaskStatus) {
        guard let existing = tasksStore.task(for: taskId) else { return }
        tasksStore.updateTask(
            id: existing.id,
            title: existing.title,
            notes: existing.notes,
            linkedBlockId: existing.linkedBlockId,
            startTime: existing.startTime,
            endTime: existing.endTime,
            reminders: existing.reminders,
            recurringReminders: existing.recurringReminders,
            recurrence: existing.recurrence,
            smartReminder: existing.smartReminder,
            status: status,
            kind: existing.kind,
            priority: existing.priority,
            tagIds: existing.tagIds,
            parentId: existing.parentId,
            estimatedMinutes: existing.estimatedMinutes,
            context: existing.context,
            horizon: existing.horizon
        )
    }
}

