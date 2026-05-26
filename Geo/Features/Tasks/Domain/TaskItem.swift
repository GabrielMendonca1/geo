import Foundation

enum TaskStatus: String, Codable, CaseIterable, Hashable {
    case pending
    case completed
}

enum TaskKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case task
    case event
    case habit
    case milestone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .task: return "Task"
        case .event: return "Event"
        case .habit: return "Habit"
        case .milestone: return "Milestone"
        }
    }

    var icon: String {
        switch self {
        case .task: return "checkmark.circle"
        case .event: return "calendar.badge.clock"
        case .habit: return "repeat.circle"
        case .milestone: return "flag.fill"
        }
    }
}

enum TaskPriority: String, Codable, CaseIterable, Hashable, Identifiable, Comparable {
    case urgent
    case high
    case medium
    case low
    case unset

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .urgent: return "Urgent"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .unset: return "None"
        }
    }

    var icon: String {
        switch self {
        case .urgent: return "exclamationmark.3"
        case .high: return "exclamationmark.2"
        case .medium: return "exclamationmark"
        case .low: return "arrow.down"
        case .unset: return "minus"
        }
    }

    var sortOrder: Int {
        switch self {
        case .urgent: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        case .unset: return 4
        }
    }

    static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

enum ReminderOffset: String, Codable, CaseIterable, Identifiable, Hashable {
    case atTime = "At time"
    case fiveMinutes = "5 minutes before"
    case fifteenMinutes = "15 minutes before"
    case thirtyMinutes = "30 minutes before"
    case oneHour = "1 hour before"
    case twoHours = "2 hours before"
    case oneDay = "1 day before"
    case twoDays = "2 days before"
    case oneWeek = "1 week before"

    var id: String { rawValue }

    var timeInterval: TimeInterval {
        switch self {
        case .atTime: return 0
        case .fiveMinutes: return -5 * 60
        case .fifteenMinutes: return -15 * 60
        case .thirtyMinutes: return -30 * 60
        case .oneHour: return -60 * 60
        case .twoHours: return -2 * 60 * 60
        case .oneDay: return -24 * 60 * 60
        case .twoDays: return -2 * 24 * 60 * 60
        case .oneWeek: return -7 * 24 * 60 * 60
        }
    }
}

enum RecurrenceFrequency: String, Codable, CaseIterable, Identifiable, Hashable {
    case daily = "Day"
    case weekly = "Week"
    case monthly = "Month"
    case yearly = "Year"

    var id: String { rawValue }

    var plural: String {
        switch self {
        case .daily: return "Days"
        case .weekly: return "Weeks"
        case .monthly: return "Months"
        case .yearly: return "Years"
        }
    }
}

struct RecurrenceRule: Codable, Hashable {
    enum RuleType: String, Codable {
        case never
        case daily
        case weekdays
        case weekly
        case biweekly
        case monthly
        case yearly
        case custom
    }

    var type: RuleType
    var customFrequency: RecurrenceFrequency?
    var customInterval: Int?
    var endDate: Date?
    var selectedWeekdays: [Int]?

    static let never = RecurrenceRule(type: .never)
    static let daily = RecurrenceRule(type: .daily)
    static let weekdays = RecurrenceRule(type: .weekdays)
    static let weekly = RecurrenceRule(type: .weekly)
    static let biweekly = RecurrenceRule(type: .biweekly)
    static let monthly = RecurrenceRule(type: .monthly)
    static let yearly = RecurrenceRule(type: .yearly)

    static func custom(every interval: Int, frequency: RecurrenceFrequency) -> RecurrenceRule {
        RecurrenceRule(type: .custom, customFrequency: frequency, customInterval: max(1, interval))
    }

    static func weekly(on weekdays: [Int], until endDate: Date? = nil) -> RecurrenceRule {
        RecurrenceRule(type: .weekly, endDate: endDate, selectedWeekdays: weekdays)
    }

    private static var endDateFormatter: DateFormatter { DateFormatters.mediumDate }

    init(
        type: RuleType,
        customFrequency: RecurrenceFrequency? = nil,
        customInterval: Int? = nil,
        endDate: Date? = nil,
        selectedWeekdays: [Int]? = nil
    ) {
        self.type = type
        self.customFrequency = customFrequency
        self.customInterval = customInterval
        self.endDate = endDate
        self.selectedWeekdays = selectedWeekdays
    }

    var displayName: String {
        var base: String
        switch type {
        case .never: return "Never"
        case .daily: base = "Daily"
        case .weekdays: base = "Weekdays"
        case .weekly: base = "Weekly"
        case .biweekly: base = "Every 2 weeks"
        case .monthly: base = "Monthly"
        case .yearly: base = "Yearly"
        case .custom:
            let interval = customInterval ?? 1
            let frequency = customFrequency ?? .daily
            let unit = interval == 1 ? frequency.rawValue : frequency.plural
            base = "Every \(interval) \(unit)"
        }

        if let days = selectedWeekdays, !days.isEmpty {
            let names = days.sorted().compactMap { Self.shortWeekdayName(for: $0) }
            if !names.isEmpty {
                base += " on \(names.joined(separator: ", "))"
            }
        }

        if let endDate {
            base += " until \(Self.endDateFormatter.string(from: endDate))"
        }

        return base
    }

    var isRepeating: Bool {
        switch type {
        case .never:
            return false
        case .daily, .weekdays, .weekly, .biweekly, .monthly, .yearly, .custom:
            return true
        }
    }

    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        let candidate: Date?

        switch type {
        case .never:
            return nil
        case .daily:
            candidate = calendar.date(byAdding: .day, value: 1, to: date)
        case .weekdays:
            var next = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            var safety = 0
            while calendar.isDateInWeekend(next), safety < 7 {
                next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
                safety += 1
            }
            candidate = next
        case .weekly:
            candidate = nextWeekdayAwareDate(after: date, weekInterval: 1, calendar: calendar)
        case .biweekly:
            candidate = nextWeekdayAwareDate(after: date, weekInterval: 2, calendar: calendar)
        case .monthly:
            candidate = calendar.date(byAdding: .month, value: 1, to: date)
        case .yearly:
            candidate = calendar.date(byAdding: .year, value: 1, to: date)
        case .custom:
            let interval = customInterval ?? 1
            if (customFrequency ?? .daily) == .weekly {
                candidate = nextWeekdayAwareDate(after: date, weekInterval: interval, calendar: calendar)
            } else {
                let component: Calendar.Component
                switch customFrequency ?? .daily {
                case .daily: component = .day
                case .weekly: component = .weekOfYear
                case .monthly: component = .month
                case .yearly: component = .year
                }
                candidate = calendar.date(byAdding: component, value: interval, to: date)
            }
        }

        guard let advanced = candidate else { return nil }
        let result = Self.reanchorTime(of: advanced, from: date, calendar: calendar)
        if let endDate, result > endDate { return nil }
        return result
    }

    private static func reanchorTime(of target: Date, from source: Date, calendar: Calendar) -> Date {
        let time = calendar.dateComponents([.hour, .minute, .second], from: source)
        return calendar.date(bySettingHour: time.hour ?? 0,
                             minute: time.minute ?? 0,
                             second: time.second ?? 0,
                             of: target) ?? target
    }

    private func nextWeekdayAwareDate(after date: Date, weekInterval: Int, calendar: Calendar) -> Date? {
        guard let days = selectedWeekdays, !days.isEmpty else {
            return calendar.date(byAdding: .weekOfYear, value: weekInterval, to: date)
        }

        let currentWeekday = calendar.component(.weekday, from: date)
        let sortedDays = days.sorted()

        if let nextDay = sortedDays.first(where: { $0 > currentWeekday }) {
            let diff = nextDay - currentWeekday
            return calendar.date(byAdding: .day, value: diff, to: date)
        }

        guard let firstDay = sortedDays.first else { return nil }
        let daysUntilEndOfWeek = 7 - currentWeekday + firstDay
        let extraWeeks = weekInterval - 1
        return calendar.date(byAdding: .day, value: daysUntilEndOfWeek + (extraWeeks * 7), to: date)
    }

    private static func shortWeekdayName(for weekday: Int) -> String? {
        switch weekday {
        case 1: return "Sun"
        case 2: return "Mon"
        case 3: return "Tue"
        case 4: return "Wed"
        case 5: return "Thu"
        case 6: return "Fri"
        case 7: return "Sat"
        default: return nil
        }
    }
}

struct RecurringReminder: Identifiable, Codable, Hashable {
    let id: UUID
    var interval: Int {
        didSet {
            if interval < 1 {
                interval = 1
            }
        }
    }
    var frequency: RecurrenceFrequency
    var timeOfDay: Date
    var lastFired: Date?

    init(
        id: UUID = UUID(),
        interval: Int = 1,
        frequency: RecurrenceFrequency = .daily,
        timeOfDay: Date = Date(),
        lastFired: Date? = nil
    ) {
        self.id = id
        self.interval = max(1, interval)
        self.frequency = frequency
        self.timeOfDay = timeOfDay
        self.lastFired = lastFired
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case interval
        case frequency
        case timeOfDay
        case lastFired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        interval = max(1, try container.decode(Int.self, forKey: .interval))
        frequency = try container.decode(RecurrenceFrequency.self, forKey: .frequency)
        timeOfDay = try container.decode(Date.self, forKey: .timeOfDay)
        lastFired = try container.decodeIfPresent(Date.self, forKey: .lastFired)
    }

    func nextFireDate(after date: Date) -> Date? {
        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute], from: timeOfDay)
        let safeInterval = max(1, interval)

        let baseDate: Date
        switch frequency {
        case .daily:
            baseDate = calendar.date(byAdding: .day, value: safeInterval, to: date) ?? date
        case .weekly:
            baseDate = calendar.date(byAdding: .weekOfYear, value: safeInterval, to: date) ?? date
        case .monthly:
            baseDate = calendar.date(byAdding: .month, value: safeInterval, to: date) ?? date
        case .yearly:
            baseDate = calendar.date(byAdding: .year, value: safeInterval, to: date) ?? date
        }

        let hour = timeComponents.hour ?? 0
        let minute = timeComponents.minute ?? 0
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: baseDate)
    }
}

struct TaskDraft: Hashable, Sendable {
    var title: String
    var notes: String
    var linkedBlockId: String?
    var startTime: Date
    var endTime: Date?
    var reminders: [ReminderOffset]
    var recurringReminders: [RecurringReminder]
    var recurrence: RecurrenceRule
    var smartReminder: Bool
    var kind: TaskKind
    var priority: TaskPriority
    var tagIds: [String]
    var parentId: String?
    var estimatedMinutes: Int?
    var context: String?

    init(
        title: String,
        notes: String = "",
        linkedBlockId: String? = nil,
        startTime: Date,
        endTime: Date? = nil,
        reminders: [ReminderOffset] = [.atTime],
        recurringReminders: [RecurringReminder] = [],
        recurrence: RecurrenceRule = .never,
        smartReminder: Bool = false,
        kind: TaskKind = .task,
        priority: TaskPriority = .unset,
        tagIds: [String] = [],
        parentId: String? = nil,
        estimatedMinutes: Int? = nil,
        context: String? = nil
    ) {
        self.title = title
        self.notes = notes
        self.linkedBlockId = linkedBlockId
        self.startTime = startTime
        self.endTime = endTime
        self.reminders = reminders
        self.recurringReminders = recurringReminders
        self.recurrence = recurrence
        self.smartReminder = smartReminder
        self.kind = kind
        self.priority = priority
        self.tagIds = tagIds
        self.parentId = parentId
        self.estimatedMinutes = estimatedMinutes
        self.context = context
    }
}

struct TaskItem: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var notes: String
    var linkedBlockId: String?
    var status: TaskStatus
    var startTime: Date
    var endTime: Date?
    var reminders: [ReminderOffset]
    var recurringReminders: [RecurringReminder]
    var recurrence: RecurrenceRule
    var firedReminders: [ReminderOffset]
    var orderIndex: Int
    var smartReminder: Bool
    var snoozedUntil: Date?
    let createdAt: Date
    var modifiedAt: Date
    var kind: TaskKind
    var priority: TaskPriority
    var tagIds: [String]
    var parentId: String?
    var estimatedMinutes: Int?
    var context: String?
    var completionHistory: [Date]
    var currentStreak: Int
    var longestStreak: Int
    var schedule: Schedule
    var scheduleAlerts: ScheduleAlerts
    var habitState: HabitState?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case notes
        case linkedBlockId
        case status
        case startTime
        case endTime
        case reminders
        case recurringReminders
        case recurrence
        case firedReminders
        case orderIndex
        case smartReminder
        case snoozedUntil
        case createdAt
        case modifiedAt
        case kind
        case priority
        case tagIds
        case parentId
        case estimatedMinutes
        case context
        case completionHistory
        case currentStreak
        case longestStreak
        case schedule
        case scheduleAlerts
        case habitState
    }

    init(
        id: String,
        title: String,
        notes: String = "",
        linkedBlockId: String? = nil,
        status: TaskStatus = .pending,
        startTime: Date,
        endTime: Date? = nil,
        reminders: [ReminderOffset] = [.atTime],
        recurringReminders: [RecurringReminder] = [],
        recurrence: RecurrenceRule = .never,
        firedReminders: [ReminderOffset] = [],
        orderIndex: Int = 0,
        smartReminder: Bool = false,
        snoozedUntil: Date? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        kind: TaskKind = .task,
        priority: TaskPriority = .unset,
        tagIds: [String] = [],
        parentId: String? = nil,
        estimatedMinutes: Int? = nil,
        context: String? = nil,
        completionHistory: [Date] = [],
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        schedule: Schedule? = nil,
        scheduleAlerts: ScheduleAlerts? = nil,
        habitState: HabitState? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.linkedBlockId = linkedBlockId
        self.status = status
        self.startTime = startTime
        self.endTime = endTime
        self.reminders = reminders
        self.recurringReminders = recurringReminders
        self.recurrence = recurrence
        self.firedReminders = firedReminders
        self.orderIndex = orderIndex
        self.smartReminder = smartReminder
        self.snoozedUntil = snoozedUntil
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.kind = kind
        self.priority = priority
        self.tagIds = tagIds
        self.parentId = parentId
        self.estimatedMinutes = estimatedMinutes
        self.context = context
        self.completionHistory = completionHistory
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.schedule = schedule ?? Schedule.fromLegacyFields(
            kind: kind,
            startTime: startTime,
            endTime: endTime,
            recurrence: recurrence
        )
        self.scheduleAlerts = scheduleAlerts ?? ScheduleAlerts.fromLegacyFields(
            reminders: reminders,
            recurringReminders: recurringReminders,
            firedReminders: firedReminders,
            smartReminder: smartReminder,
            snoozedUntil: snoozedUntil
        )
        if let habitState {
            self.habitState = habitState
        } else {
            self.habitState = HabitState.fromLegacyFields(
                kind: kind,
                completionHistory: completionHistory,
                currentStreak: currentStreak,
                longestStreak: longestStreak
            )
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decode(String.self, forKey: .notes)
        linkedBlockId = try container.decodeIfPresent(String.self, forKey: .linkedBlockId)
        status = try container.decode(TaskStatus.self, forKey: .status)
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        reminders = try container.decode([ReminderOffset].self, forKey: .reminders)
        recurringReminders = try container.decode([RecurringReminder].self, forKey: .recurringReminders)
        recurrence = try container.decode(RecurrenceRule.self, forKey: .recurrence)
        firedReminders = try container.decode([ReminderOffset].self, forKey: .firedReminders)
        orderIndex = try container.decode(Int.self, forKey: .orderIndex)
        smartReminder = try container.decode(Bool.self, forKey: .smartReminder)
        snoozedUntil = try container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        kind = try container.decodeIfPresent(TaskKind.self, forKey: .kind) ?? .task
        priority = try container.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .unset
        tagIds = try container.decodeIfPresent([String].self, forKey: .tagIds) ?? []
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        context = try container.decodeIfPresent(String.self, forKey: .context)
        completionHistory = try container.decodeIfPresent([Date].self, forKey: .completionHistory) ?? []
        currentStreak = try container.decodeIfPresent(Int.self, forKey: .currentStreak) ?? 0
        longestStreak = try container.decodeIfPresent(Int.self, forKey: .longestStreak) ?? 0

        if let decodedSchedule = try container.decodeIfPresent(Schedule.self, forKey: .schedule) {
            schedule = decodedSchedule
        } else {
            schedule = Schedule.fromLegacyFields(
                kind: kind,
                startTime: startTime,
                endTime: endTime,
                recurrence: recurrence
            )
        }

        if let decodedAlerts = try container.decodeIfPresent(ScheduleAlerts.self, forKey: .scheduleAlerts) {
            scheduleAlerts = decodedAlerts
        } else {
            scheduleAlerts = ScheduleAlerts.fromLegacyFields(
                reminders: reminders,
                recurringReminders: recurringReminders,
                firedReminders: firedReminders,
                smartReminder: smartReminder,
                snoozedUntil: snoozedUntil
            )
        }

        if let decodedHabit = try container.decodeIfPresent(HabitState.self, forKey: .habitState) {
            habitState = decodedHabit
        } else {
            habitState = HabitState.fromLegacyFields(
                kind: kind,
                completionHistory: completionHistory,
                currentStreak: currentStreak,
                longestStreak: longestStreak
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(linkedBlockId, forKey: .linkedBlockId)
        try container.encode(status, forKey: .status)
        try container.encode(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encode(reminders, forKey: .reminders)
        try container.encode(recurringReminders, forKey: .recurringReminders)
        try container.encode(recurrence, forKey: .recurrence)
        try container.encode(firedReminders, forKey: .firedReminders)
        try container.encode(orderIndex, forKey: .orderIndex)
        try container.encode(smartReminder, forKey: .smartReminder)
        try container.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(kind, forKey: .kind)
        try container.encode(priority, forKey: .priority)
        try container.encode(tagIds, forKey: .tagIds)
        try container.encodeIfPresent(parentId, forKey: .parentId)
        try container.encodeIfPresent(estimatedMinutes, forKey: .estimatedMinutes)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encode(completionHistory, forKey: .completionHistory)
        try container.encode(currentStreak, forKey: .currentStreak)
        try container.encode(longestStreak, forKey: .longestStreak)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(scheduleAlerts, forKey: .scheduleAlerts)
        try container.encodeIfPresent(habitState, forKey: .habitState)
    }
}

extension TaskItem {
    var isPeriodTask: Bool { endTime != nil }
    var isHabit: Bool { kind == .habit }
    var isEvent: Bool { kind == .event }
    var isMilestone: Bool { kind == .milestone }

    var hasSubtasks: Bool { false }

    var daysUntilMilestone: Int? {
        guard kind == .milestone, status == .pending else { return nil }
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: startTime)
        return calendar.dateComponents([.day], from: now, to: target).day
    }

    var estimatedDuration: String? {
        guard let minutes = estimatedMinutes, minutes > 0 else { return nil }
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(remainder)m"
    }

    var priorityColor: String {
        switch priority {
        case .urgent: return "red"
        case .high: return "orange"
        case .medium: return "yellow"
        case .low: return "blue"
        case .unset: return "gray"
        }
    }

    mutating func recordHabitCompletion(at date: Date = Date()) {
        guard kind == .habit else { return }
        completionHistory.append(date)
        let calendar = Calendar.current
        let sorted = completionHistory.sorted()
        var streak = 1
        for i in stride(from: sorted.count - 1, through: 1, by: -1) {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: sorted[i - 1]), to: calendar.startOfDay(for: sorted[i])).day ?? 0
            if days <= 1 {
                streak += 1
            } else {
                break
            }
        }
        currentStreak = streak
        longestStreak = max(longestStreak, streak)
    }

    func nextReminderTime(at date: Date = Date()) -> Date? {
        guard status == .pending else { return nil }
        let reminders = reminders.sorted { $0.timeInterval < $1.timeInterval }
        for reminder in reminders {
            if firedReminders.contains(reminder) { continue }
            let reminderTime = startTime.addingTimeInterval(reminder.timeInterval)
            if reminderTime > date {
                return reminderTime
            }
        }
        return nil
    }

    var nextReminderTime: Date? { nextReminderTime(at: Date()) }

    func isDue(at date: Date) -> Bool {
        guard status == .pending else { return false }

        if let snoozedUntil = snoozedUntil {
            return snoozedUntil <= date
        }

        let unfired = reminders.filter { !firedReminders.contains($0) }

        return unfired.contains { reminder in
            let reminderTime = startTime.addingTimeInterval(reminder.timeInterval)
            return reminderTime <= date
        }
    }

    func currentDueReminder(at date: Date) -> ReminderOffset? {
        guard status == .pending, snoozedUntil == nil else { return nil }

        let unfired = reminders.filter { !firedReminders.contains($0) }

        return unfired.first { reminder in
            let reminderTime = startTime.addingTimeInterval(reminder.timeInterval)
            return reminderTime <= date
        }
    }

    var currentDueReminder: ReminderOffset? { currentDueReminder(at: Date()) }

    var isOverdue: Bool {
        guard status == .pending else { return false }
        guard !recurrence.isRepeating else { return false }
        let now = Date()
        if let snoozedUntil, snoozedUntil > now { return false }
        if let endTime {
            return endTime < now
        }
        return startTime < Calendar.current.startOfDay(for: now)
    }
}
