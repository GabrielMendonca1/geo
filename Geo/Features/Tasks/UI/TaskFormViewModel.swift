import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "TaskFormViewModel")

@MainActor
final class TaskFormViewModel: ObservableObject {
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?

    @Published var kind: TaskKind = .task
    @Published var title: String = ""
    @Published var notes: String = ""
    @Published var taskStatus: TaskStatus = .pending
    @Published var priority: TaskPriority = .unset
    @Published var context: String = ""

    @Published var date: Date
    @Published var time: Date
    @Published var hasEndDate: Bool = false
    @Published var endDate: Date
    @Published var endTime: Date
    @Published var isAllDay: Bool = false
    @Published var location: String = ""

    @Published var hasEstimate: Bool = false
    @Published var estimatedMinutes: Int = 30

    @Published var recurrenceType: RecurrenceRule.RuleType = .never
    @Published var customFrequency: RecurrenceFrequency = .daily
    @Published var customInterval: Int = 1
    @Published var hasRecurrenceEndDate: Bool = false
    @Published var recurrenceEndDate: Date
    @Published var selectedWeekdays: Set<Int> = []

    @Published var reminders: Set<ReminderOffset> = [.atTime]
    @Published var smartReminder: Bool = false
    @Published var recurringReminders: [RecurringReminder] = []

    @Published var linkedBlockId: String?
    @Published var resetCheckboxesOnComplete: Bool = true

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
            return "Streak: \(task.currentStreak)d"
        }
        if kind == .milestone, let task = editingTask, let days = task.daysUntilMilestone {
            return days >= 0 ? "\(days)d remaining" : "\(-days)d overdue"
        }
        return "Pending"
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
        notes = task.notes
        date = task.startTime
        time = task.startTime
        taskStatus = task.status
        reminders = Set(task.reminders)
        linkedBlockId = task.linkedBlockId
        recurringReminders = task.recurringReminders
        smartReminder = task.smartReminder
        recurrenceType = task.recurrence.type
        if task.recurrence.type == .custom {
            customFrequency = task.recurrence.customFrequency ?? .daily
            customInterval = task.recurrence.customInterval ?? 1
        }
        if let rEnd = task.recurrence.endDate {
            hasRecurrenceEndDate = true
            recurrenceEndDate = rEnd
        }
        if let days = task.recurrence.selectedWeekdays {
            selectedWeekdays = Set(days)
        }
        kind = task.kind
        priority = task.priority
        estimatedMinutes = task.estimatedMinutes ?? 30
        hasEstimate = task.estimatedMinutes != nil
        context = task.context ?? ""
        if let end = task.endTime {
            hasEndDate = true
            endDate = end
            endTime = end
        }
        resetCheckboxesOnComplete = task.habitState?.resetCheckboxesOnComplete ?? true
    }

    func requestKindSwitch(to newKind: TaskKind) {
        guard newKind != kind else { return }
        let previous = kind

        if previous == .habit,
           editingTask != nil,
           !(editingTask?.completionHistory.isEmpty ?? true),
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
                let now = Date()
                date = now
                time = now
                endDate = now
                endTime = now.addingTimeInterval(3600)
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
                task.notes = draft.notes
                task.linkedBlockId = draft.linkedBlockId
                task.status = taskStatus
                task.startTime = draft.startTime
                task.endTime = draft.endTime
                task.reminders = draft.reminders
                task.recurringReminders = draft.recurringReminders
                task.recurrence = draft.recurrence
                task.smartReminder = draft.smartReminder
                task.kind = draft.kind
                task.priority = draft.priority
                task.tagIds = draft.tagIds
                task.parentId = draft.parentId
                task.estimatedMinutes = draft.estimatedMinutes
                task.context = draft.context
                task.modifiedAt = Date()
                if task.kind == .habit {
                    if task.habitState == nil {
                        task.habitState = HabitState.fromLegacyFields(
                            kind: .habit,
                            completionHistory: task.completionHistory,
                            currentStreak: task.currentStreak,
                            longestStreak: task.longestStreak
                        )
                    }
                    task.habitState?.resetCheckboxesOnComplete = resetCheckboxesOnComplete
                }
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

    private func buildDraft() -> TaskDraft {
        let resolvedRecurrenceEnd: Date? = hasRecurrenceEndDate ? recurrenceEndDate : nil
        let resolvedWeekdays: [Int]? = selectedWeekdays.isEmpty ? nil : Array(selectedWeekdays)

        let recurrence: RecurrenceRule
        if recurrenceType == .custom {
            var rule = RecurrenceRule.custom(every: max(1, customInterval), frequency: customFrequency)
            rule.endDate = resolvedRecurrenceEnd
            rule.selectedWeekdays = resolvedWeekdays
            recurrence = rule
        } else {
            recurrence = RecurrenceRule(
                type: recurrenceType,
                endDate: resolvedRecurrenceEnd,
                selectedWeekdays: resolvedWeekdays
            )
        }

        let sanitizedRecurringReminders = recurringReminders.map { reminder in
            var sanitized = reminder
            sanitized.interval = max(1, sanitized.interval)
            return sanitized
        }

        let effectiveReminders: [ReminderOffset]
        if kind == .milestone {
            effectiveReminders = []
        } else {
            effectiveReminders = Array(reminders)
        }

        let trimmedNotes: String
        if kind == .event, !location.isEmpty {
            if notes.isEmpty {
                trimmedNotes = "Location: \(location)"
            } else {
                trimmedNotes = notes + "\n\nLocation: \(location)"
            }
        } else {
            trimmedNotes = notes
        }

        return TaskDraft(
            title: trimmedTitle,
            notes: trimmedNotes,
            linkedBlockId: linkedBlockId,
            startTime: resolvedStartTime,
            endTime: resolvedEndTime,
            reminders: effectiveReminders,
            recurringReminders: sanitizedRecurringReminders,
            recurrence: recurrence,
            smartReminder: kind == .milestone ? false : smartReminder,
            kind: kind,
            priority: priority,
            estimatedMinutes: hasEstimate ? estimatedMinutes : nil,
            context: context.isEmpty ? nil : context
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

    private static func today() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    private static func defaultTime() -> Date {
        Date()
    }

    private static func defaultHabitTime() -> Date {
        let calendar = Calendar.current
        return calendar.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private static func dateInDays(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }
}
