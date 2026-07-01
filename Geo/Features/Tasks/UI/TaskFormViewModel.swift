import Foundation
import GeoCore
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "TaskFormViewModel")

@MainActor
final class TaskFormViewModel: ObservableObject {
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?

    @Published var kind: TaskKind = .task
    @Published var title: String = ""
    @Published var taskStatus: TaskStatus = .pending
    @Published var priority: TaskPriority = .unset

    @Published var date: Date
    @Published var time: Date
    @Published var hasEndDate: Bool = false
    @Published var endDate: Date
    @Published var endTime: Date
    @Published var isAllDay: Bool = false

    @Published var hasEstimate: Bool = false
    @Published var estimatedMinutes: Int = 30

    @Published var recurrenceType: RecurrenceRule.RuleType = .never
    @Published var customFrequency: RecurrenceFrequency = .daily
    @Published var customInterval: Int = 1
    @Published var hasRecurrenceEndDate: Bool = false
    @Published var recurrenceEndDate: Date
    @Published var selectedWeekdays: Set<Int> = []

    @Published var reminders: Set<ReminderOffset> = [.atTime]

    @Published var linkedBlockId: String?

    @Published var pendingKindSwitch: PendingKindSwitch?
    @Published var pendingHabitTimeChoice: PendingHabitTimeChoice?

    private(set) var editingTask: TaskItem?
    private var didLoadEditingTask = false

    init() {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        self.date = today
        self.time = now
        self.endDate = today
        self.endTime = now.addingTimeInterval(3600)
        self.recurrenceEndDate = today
    }

    struct PendingKindSwitch: Identifiable {
        let id = UUID()
        let from: TaskKind
        let to: TaskKind
        let message: String
    }

    struct PendingHabitTimeChoice: Identifiable {
        let id = UUID()
        let candidateTime: Date
    }

    var isEditing: Bool { editingTask != nil }

    var resolvedStartTime: Date {
        Self.combine(date: date, time: time) ?? time
    }

    var resolvedEndTime: Date? {
        guard hasEndDate else { return nil }
        return Self.combine(date: endDate, time: endTime)
    }

    var hasValidDateRange: Bool {
        guard hasEndDate else { return true }
        guard let end = resolvedEndTime else { return false }
        return end >= resolvedStartTime
    }

    var validationMessage: String? {
        hasValidDateRange ? nil : "End date/time must be later than the start date/time."
    }

    var canSave: Bool {
        !trimmedTitle.isEmpty && hasValidDateRange
    }

    var trimmedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    var subtitleText: String {
        isEditing
            ? "Update details, schedule, recurrence, and reminders."
            : "Capture a \(kind.displayName.lowercased()) with sensible defaults."
    }

    var headerBadgeText: String {
        if taskStatus == .completed { return "Completed" }
        if kind == .habit, let task = editingTask {
            return "Streak: \(task.habitCurrentStreak)d"
        }
        if kind == .milestone, let task = editingTask, let days = task.daysUntilMilestone {
            return days >= 0 ? "\(days)d remaining" : "\(-days)d overdue"
        }
        return "Pending"
    }

    func applyPrefillDate(_ prefill: Date) {
        date = prefill
        time = prefill
        endDate = prefill
        endTime = prefill.addingTimeInterval(3600)
    }

    func loadEditingTaskIfNeeded(_ task: TaskItem?) {
        guard !didLoadEditingTask else { return }
        didLoadEditingTask = true
        editingTask = task
        guard let task else {
            applyKindDefaults(kind, force: true)
            return
        }
        title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        taskStatus = task.status
        reminders = Set(task.reminders.compactMap { r -> ReminderOffset? in
            if case .offset(let off) = r.trigger { return off }
            return nil
        })
        linkedBlockId = task.linkedBlockId
        priority = task.priority
        estimatedMinutes = task.estimatedMinutes ?? 30
        hasEstimate = task.estimatedMinutes != nil
        kind = task.kind

        switch task.body {
        case .task(let due, _):
            date = due
            time = due
        case .event(let start, let end, _):
            date = start
            time = start
            hasEndDate = true
            endDate = end
            endTime = end
        case .habit(let rule, let tod, _):
            date = tod
            time = tod
            recurrenceType = rule.type
            if rule.type == .custom {
                customFrequency = rule.customFrequency ?? .daily
                customInterval = rule.customInterval ?? 1
            }
            if let rEnd = rule.endDate {
                hasRecurrenceEndDate = true
                recurrenceEndDate = rEnd
            }
            if let days = rule.selectedWeekdays {
                selectedWeekdays = Set(days)
            }
        case .milestone(let target):
            date = target
            time = target
        }
    }

    func requestKindSwitch(to newKind: TaskKind) {
        guard newKind != kind else { return }
        let previous = kind

        if previous == .habit,
           let editing = editingTask,
           !editing.habitOccurrences.isEmpty,
           newKind != .habit {
            pendingKindSwitch = PendingKindSwitch(
                from: previous,
                to: newKind,
                message: "Switching away from Habit will lose streak history. Continue?"
            )
            return
        }

        applyKindSwitch(to: newKind, from: previous)
    }

    func confirmPendingKindSwitch() {
        guard let pending = pendingKindSwitch else { return }
        pendingKindSwitch = nil
        applyKindSwitch(to: pending.to, from: pending.from)
    }

    func cancelPendingKindSwitch() {
        pendingKindSwitch = nil
    }

    func acceptHabitTimeChoice(useCurrentTime: Bool) {
        guard let pending = pendingHabitTimeChoice else { return }
        pendingHabitTimeChoice = nil
        if !useCurrentTime {
            time = Self.defaultHabitTime()
        } else {
            time = pending.candidateTime
        }
    }

    private func applyKindSwitch(to newKind: TaskKind, from previous: TaskKind) {
        if newKind == .habit, previous != .habit {
            let calendar = Calendar.current
            let comps = calendar.dateComponents([.hour, .minute], from: time)
            let nonDefault = (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0
            if nonDefault {
                pendingHabitTimeChoice = PendingHabitTimeChoice(candidateTime: time)
            }
        }

        if newKind == .habit, previous != .habit, recurrenceType == .never {
            recurrenceType = .daily
        }

        if newKind != .habit, previous == .habit {
            if pendingHabitTimeChoice != nil { pendingHabitTimeChoice = nil }
        }

        kind = newKind
        applyKindDefaults(newKind, force: false)
    }

    private func applyKindDefaults(_ kind: TaskKind, force: Bool) {
        switch kind {
        case .task:
            if force {
                hasEndDate = false
                recurrenceType = .never
            }
        case .event:
            if force || !hasEndDate {
                hasEndDate = true
                endDate = date
                endTime = time.addingTimeInterval(3600)
            }
        case .habit:
            if force || recurrenceType == .never {
                recurrenceType = .daily
            }
            if force {
                time = Self.defaultHabitTime()
                hasEndDate = false
            }
        case .milestone:
            if force {
                date = Self.dateInDays(30)
                hasEndDate = false
                recurrenceType = .never
            }
        }
    }

    func save(repository: any TasksRepository) async -> Bool {
        guard !isSaving else { return false }
        guard canSave else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let draft = buildDraft()

        do {
            if var task = editingTask {
                task.title = draft.title
                task.linkedBlockId = draft.linkedBlockId
                task.status = taskStatus
                task.body = preserveOccurrencesIfHabit(old: task.body, new: draft.body)
                task.reminders = draft.reminders
                task.priority = draft.priority
                task.tagIds = draft.tagIds
                task.estimatedMinutes = draft.estimatedMinutes
                task.modifiedAt = Date()
                try await repository.update(task)
            } else {
                _ = try await repository.create(draft)
            }
            return true
        } catch {
            logger.error("Failed to save task: \(error.localizedDescription)")
            saveError = error.localizedDescription
            return false
        }
    }

    private func preserveOccurrencesIfHabit(old: TaskBody, new: TaskBody) -> TaskBody {
        if case .habit(_, _, let oldOccs) = old, case .habit(let rule, let tod, _) = new {
            return .habit(rule: rule, timeOfDay: tod, occurrences: oldOccs)
        }
        return new
    }

    private func buildDraft() -> TaskDraft {
        let body = buildBody()
        let effectiveReminders: [Reminder]
        if kind == .milestone {
            effectiveReminders = []
        } else {
            effectiveReminders = reminders.map { Reminder(trigger: .offset($0)) }
        }

        return TaskDraft(
            title: trimmedTitle,
            linkedBlockId: linkedBlockId,
            status: taskStatus,
            priority: priority,
            tagIds: [],
            estimatedMinutes: hasEstimate ? estimatedMinutes : nil,
            body: body,
            reminders: effectiveReminders.isEmpty ? [] : effectiveReminders
        )
    }

    private func buildBody() -> TaskBody {
        switch kind {
        case .task:
            return .task(due: resolvedStartTime, estimatedMinutes: hasEstimate ? estimatedMinutes : nil)
        case .event:
            let end = resolvedEndTime ?? resolvedStartTime.addingTimeInterval(3600)
            return .event(start: resolvedStartTime, end: max(end, resolvedStartTime), externalEKEventID: nil)
        case .habit:
            let rule = buildRecurrenceRule()
            return .habit(rule: rule, timeOfDay: resolvedStartTime, occurrences: [])
        case .milestone:
            return .milestone(target: Calendar.current.startOfDay(for: resolvedStartTime))
        }
    }

    private func buildRecurrenceRule() -> RecurrenceRule {
        let resolvedRecurrenceEnd: Date? = hasRecurrenceEndDate ? recurrenceEndDate : nil
        let resolvedWeekdays: [Int]? = selectedWeekdays.isEmpty ? nil : Array(selectedWeekdays)

        let effectiveType: RecurrenceRule.RuleType = recurrenceType == .never ? .daily : recurrenceType

        if effectiveType == .custom {
            var rule = RecurrenceRule.custom(every: max(1, customInterval), frequency: customFrequency)
            rule.endDate = resolvedRecurrenceEnd
            rule.selectedWeekdays = resolvedWeekdays
            return rule
        }
        return RecurrenceRule(
            type: effectiveType,
            endDate: resolvedRecurrenceEnd,
            selectedWeekdays: resolvedWeekdays
        )
    }

    static func combine(date: Date, time: Date) -> Date? {
        let calendar = Calendar.current
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: time)
        var combined = DateComponents()
        combined.year = dateComponents.year
        combined.month = dateComponents.month
        combined.day = dateComponents.day
        combined.hour = timeComponents.hour
        combined.minute = timeComponents.minute
        return calendar.date(from: combined)
    }

    private static func defaultHabitTime() -> Date {
        let calendar = Calendar.current
        return calendar.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private static func dateInDays(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }
}
