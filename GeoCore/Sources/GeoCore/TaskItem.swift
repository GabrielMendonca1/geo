import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Hashable {
    case pending
    case completed
}

public enum TaskKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case task
    case event
    case habit
    case milestone

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .task: return "Task"
        case .event: return "Event"
        case .habit: return "Habit"
        case .milestone: return "Milestone"
        }
    }

    public var icon: String {
        switch self {
        case .task: return "checkmark.circle"
        case .event: return "calendar.badge.clock"
        case .habit: return "repeat.circle"
        case .milestone: return "flag.fill"
        }
    }
}

public enum TaskPriority: String, Codable, CaseIterable, Hashable, Identifiable, Comparable {
    case urgent
    case high
    case medium
    case low
    case unset

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .urgent: return "Urgent"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .unset: return "None"
        }
    }

    public var icon: String {
        switch self {
        case .urgent: return "exclamationmark.3"
        case .high: return "exclamationmark.2"
        case .medium: return "exclamationmark"
        case .low: return "arrow.down"
        case .unset: return "minus"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .urgent: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        case .unset: return 4
        }
    }

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

public enum ReminderOffset: String, Codable, CaseIterable, Identifiable, Hashable {
    case atTime = "At time"
    case fiveMinutes = "5 minutes before"
    case fifteenMinutes = "15 minutes before"
    case thirtyMinutes = "30 minutes before"
    case oneHour = "1 hour before"
    case twoHours = "2 hours before"
    case oneDay = "1 day before"
    case twoDays = "2 days before"
    case oneWeek = "1 week before"

    public var id: String { rawValue }

    public var timeInterval: TimeInterval {
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

public enum RecurrenceFrequency: String, Codable, CaseIterable, Identifiable, Hashable {
    case daily = "Day"
    case weekly = "Week"
    case monthly = "Month"
    case yearly = "Year"

    public var id: String { rawValue }

    public var plural: String {
        switch self {
        case .daily: return "Days"
        case .weekly: return "Weeks"
        case .monthly: return "Months"
        case .yearly: return "Years"
        }
    }
}

public struct RecurrenceRule: Codable, Hashable {
    public enum RuleType: String, Codable {
        case never
        case daily
        case weekdays
        case weekly
        case biweekly
        case monthly
        case yearly
        case custom
    }

    public var type: RuleType
    public var customFrequency: RecurrenceFrequency?
    public var customInterval: Int?
    public var endDate: Date?
    public var selectedWeekdays: [Int]?

    public static let never = RecurrenceRule(type: .never)
    public static let daily = RecurrenceRule(type: .daily)
    public static let weekdays = RecurrenceRule(type: .weekdays)
    public static let weekly = RecurrenceRule(type: .weekly)
    public static let biweekly = RecurrenceRule(type: .biweekly)
    public static let monthly = RecurrenceRule(type: .monthly)
    public static let yearly = RecurrenceRule(type: .yearly)

    public static func custom(every interval: Int, frequency: RecurrenceFrequency) -> RecurrenceRule {
        RecurrenceRule(type: .custom, customFrequency: frequency, customInterval: max(1, interval))
    }

    public static func weekly(on weekdays: [Int], until endDate: Date? = nil) -> RecurrenceRule {
        RecurrenceRule(type: .weekly, endDate: endDate, selectedWeekdays: weekdays)
    }

    private static var endDateFormatter: DateFormatter { CoreDateFormatters.mediumDate }

    public init(
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

    public var displayName: String {
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

    public var isRepeating: Bool {
        switch type {
        case .never:
            return false
        case .daily, .weekdays, .weekly, .biweekly, .monthly, .yearly, .custom:
            return true
        }
    }

    public func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
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

public enum TaskBody: Hashable {
    case task(due: Date, estimatedMinutes: Int?)
    case event(start: Date, end: Date, externalEKEventID: String?)
    case habit(rule: RecurrenceRule, timeOfDay: Date, occurrences: [Date])
    case milestone(target: Date)

    public var kind: TaskKind {
        switch self {
        case .task: return .task
        case .event: return .event
        case .habit: return .habit
        case .milestone: return .milestone
        }
    }

    public var anchorDate: Date {
        switch self {
        case .task(let due, _): return due
        case .event(let start, _, _): return start
        case .habit(_, let timeOfDay, _): return timeOfDay
        case .milestone(let target): return target
        }
    }
}

extension TaskBody: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case due
        case estimatedMinutes
        case start
        case end
        case externalEKEventID
        case rule
        case timeOfDay
        case occurrences
        case target
    }

    private enum Tag: String, Codable {
        case task, event, habit, milestone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .kind)
        switch tag {
        case .task:
            let due = try c.decode(Date.self, forKey: .due)
            let est = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
            self = .task(due: due, estimatedMinutes: est)
        case .event:
            let start = try c.decode(Date.self, forKey: .start)
            let end = try c.decode(Date.self, forKey: .end)
            let externalID = try c.decodeIfPresent(String.self, forKey: .externalEKEventID)
            self = .event(start: start, end: end, externalEKEventID: externalID)
        case .habit:
            let rule = try c.decode(RecurrenceRule.self, forKey: .rule)
            let tod = try c.decode(Date.self, forKey: .timeOfDay)
            let occs = try c.decodeIfPresent([Date].self, forKey: .occurrences) ?? []
            self = .habit(rule: rule, timeOfDay: tod, occurrences: occs)
        case .milestone:
            let target = try c.decode(Date.self, forKey: .target)
            self = .milestone(target: target)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .task(let due, let est):
            try c.encode(Tag.task, forKey: .kind)
            try c.encode(due, forKey: .due)
            try c.encodeIfPresent(est, forKey: .estimatedMinutes)
        case .event(let start, let end, let externalID):
            try c.encode(Tag.event, forKey: .kind)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
            try c.encodeIfPresent(externalID, forKey: .externalEKEventID)
        case .habit(let rule, let tod, let occurrences):
            try c.encode(Tag.habit, forKey: .kind)
            try c.encode(rule, forKey: .rule)
            try c.encode(tod, forKey: .timeOfDay)
            try c.encode(occurrences, forKey: .occurrences)
        case .milestone(let target):
            try c.encode(Tag.milestone, forKey: .kind)
            try c.encode(target, forKey: .target)
        }
    }
}

public enum ReminderTrigger: Hashable {
    case offset(ReminderOffset)
    case absolute(Date)
}

extension ReminderTrigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, offset, date
    }

    private enum Tag: String, Codable {
        case offset, absolute
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .kind)
        switch tag {
        case .offset:
            let raw = try c.decode(ReminderOffset.self, forKey: .offset)
            self = .offset(raw)
        case .absolute:
            self = .absolute(try c.decode(Date.self, forKey: .date))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .offset(let offset):
            try c.encode(Tag.offset, forKey: .kind)
            try c.encode(offset, forKey: .offset)
        case .absolute(let date):
            try c.encode(Tag.absolute, forKey: .kind)
            try c.encode(date, forKey: .date)
        }
    }
}

public struct Reminder: Identifiable, Codable, Hashable {
    public let id: UUID
    public var trigger: ReminderTrigger
    public var fired: Bool

    public init(id: UUID = UUID(), trigger: ReminderTrigger, fired: Bool = false) {
        self.id = id
        self.trigger = trigger
        self.fired = fired
    }

    public static func atTime() -> Reminder { Reminder(trigger: .offset(.atTime)) }

    public func fireDate(forAnchor anchor: Date) -> Date {
        switch trigger {
        case .offset(let offset): return anchor.addingTimeInterval(offset.timeInterval)
        case .absolute(let date): return date
        }
    }
}

public struct TaskDraft: Hashable, Sendable {
    public var title: String
    public var linkedBlockId: String?
    public var status: TaskStatus
    public var priority: TaskPriority
    public var tagIds: [String]
    public var orderIndex: Int
    public var estimatedMinutes: Int?
    public var body: TaskBody
    public var reminders: [Reminder]

    public init(
        title: String,
        linkedBlockId: String? = nil,
        status: TaskStatus = .pending,
        priority: TaskPriority = .unset,
        tagIds: [String] = [],
        orderIndex: Int = 0,
        estimatedMinutes: Int? = nil,
        body: TaskBody,
        reminders: [Reminder] = [.atTime()]
    ) {
        self.title = title
        self.linkedBlockId = linkedBlockId
        self.status = status
        self.priority = priority
        self.tagIds = tagIds
        self.orderIndex = orderIndex
        self.estimatedMinutes = estimatedMinutes
        self.body = body
        self.reminders = reminders
    }
}

public struct TaskItem: Identifiable, Codable, Hashable {
    public let id: String
    public var title: String
    public var linkedBlockId: String?
    public var status: TaskStatus
    public var priority: TaskPriority
    public var tagIds: [String]
    public var orderIndex: Int
    public var estimatedMinutes: Int?
    public let createdAt: Date
    public var modifiedAt: Date
    public var body: TaskBody
    public var reminders: [Reminder]
    public var externalEKEventID: String?
    public var isAllDay: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, title, linkedBlockId, status, priority, tagIds, orderIndex, estimatedMinutes, createdAt, modifiedAt, body, reminders, externalEKEventID, isAllDay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        linkedBlockId = try c.decodeIfPresent(String.self, forKey: .linkedBlockId)
        status = (try? c.decode(TaskStatus.self, forKey: .status)) ?? .pending
        priority = (try? c.decode(TaskPriority.self, forKey: .priority)) ?? .unset
        tagIds = try c.decodeIfPresent([String].self, forKey: .tagIds) ?? []
        orderIndex = try c.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        body = try c.decode(TaskBody.self, forKey: .body)
        reminders = try c.decodeIfPresent([Reminder].self, forKey: .reminders) ?? []
        externalEKEventID = Self.resolveExternalEKEventID(
            topLevel: try c.decodeIfPresent(String.self, forKey: .externalEKEventID),
            body: body
        )
        isAllDay = try c.decodeIfPresent(Bool.self, forKey: .isAllDay)
    }

    public init(
        id: String,
        title: String,
        linkedBlockId: String? = nil,
        status: TaskStatus = .pending,
        priority: TaskPriority = .unset,
        tagIds: [String] = [],
        orderIndex: Int = 0,
        estimatedMinutes: Int? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        body: TaskBody,
        reminders: [Reminder] = [.atTime()],
        externalEKEventID: String? = nil,
        isAllDay: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.linkedBlockId = linkedBlockId
        self.status = status
        self.priority = priority
        self.tagIds = tagIds
        self.orderIndex = orderIndex
        self.estimatedMinutes = estimatedMinutes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.body = body
        self.reminders = reminders
        self.externalEKEventID = Self.resolveExternalEKEventID(topLevel: externalEKEventID, body: body)
        self.isAllDay = isAllDay
    }

    private static func resolveExternalEKEventID(topLevel: String?, body: TaskBody) -> String? {
        if let topLevel { return topLevel }
        if case .event(_, _, let legacyID) = body { return legacyID }
        return nil
    }
}

public extension TaskItem {
    var kind: TaskKind { body.kind }
    var anchorDate: Date { body.anchorDate }

    var resolvedIsAllDay: Bool {
        if let isAllDay { return isAllDay }
        let c = Calendar.current.dateComponents([.hour, .minute], from: body.anchorDate)
        return (c.hour == 0 && c.minute == 0) || (c.hour == 23 && c.minute == 59)
    }

    var isTask: Bool { if case .task = body { return true }; return false }
    var isEvent: Bool { if case .event = body { return true }; return false }
    var isHabit: Bool { if case .habit = body { return true }; return false }
    var isMilestone: Bool { if case .milestone = body { return true }; return false }

    var startTime: Date { anchorDate }

    var endTime: Date? {
        if case .event(_, let end, _) = body { return end }
        return nil
    }

    var recurrence: RecurrenceRule {
        if case .habit(let rule, _, _) = body { return rule }
        return .never
    }

    private static let scheduleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var scheduleDisplayLabel: String {
        let short = Self.scheduleDateFormatter
        let timeOnly = CoreDateFormatters.shortTime
        switch body {
        case .task(let due, _):
            return "Due \(short.string(from: due))"
        case .event(let start, let end, _):
            return "\(short.string(from: start)) – \(timeOnly.string(from: end))"
        case .habit(let rule, let tod, _):
            return "\(rule.displayName) at \(timeOnly.string(from: tod))"
        case .milestone(let target):
            return "Target \(short.string(from: target))"
        }
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

    var estimatedDuration: String? {
        guard let minutes = estimatedMinutes, minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    var daysUntilMilestone: Int? {
        guard case .milestone(let target) = body, status == .pending else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: target)
        ).day
    }

    var habitOccurrences: [Date] {
        if case .habit(_, _, let occurrences) = body { return occurrences }
        return []
    }

    var habitCurrentStreak: Int { Self.computeStreaks(history: habitOccurrences).current }
    var habitLongestStreak: Int { Self.computeStreaks(history: habitOccurrences).longest }

    var isHabitCompletedToday: Bool {
        guard case .habit = body else { return false }
        return habitOccurrences.contains { Calendar.current.isDate($0, inSameDayAs: Date()) }
    }

    var isOverdue: Bool {
        guard status == .pending else { return false }
        let now = Date()
        switch body {
        case .task(let due, _):
            return due < Calendar.current.startOfDay(for: now)
        case .event(_, let end, _):
            return end < now
        case .habit, .milestone:
            return false
        }
    }

    var isFuture: Bool {
        guard status == .pending else { return false }
        let calendar = Calendar.current
        let startOfTomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: Date())!)
        switch body {
        case .task(let due, _):
            return due >= startOfTomorrow
        case .event(let start, _, _):
            return start >= startOfTomorrow
        case .habit, .milestone:
            return false
        }
    }

    func isDue(at date: Date) -> Bool {
        guard status == .pending else { return false }
        let anchor = body.anchorDate
        return reminders.contains { !$0.fired && $0.fireDate(forAnchor: anchor) <= date }
    }

    func currentDueReminder(at date: Date = Date()) -> Reminder? {
        guard status == .pending else { return nil }
        let anchor = body.anchorDate
        return reminders.first { !$0.fired && $0.fireDate(forAnchor: anchor) <= date }
    }

    static func computeStreaks(history: [Date], calendar: Calendar = .current) -> (current: Int, longest: Int) {
        guard !history.isEmpty else { return (0, 0) }
        let sortedDays = history.map { calendar.startOfDay(for: $0) }.sorted()
        var longest = 1
        var run = 1
        for i in 1..<sortedDays.count {
            let gap = calendar.dateComponents([.day], from: sortedDays[i - 1], to: sortedDays[i]).day ?? 0
            if gap == 0 { continue }
            if gap == 1 { run += 1 } else { run = 1 }
            longest = max(longest, run)
        }
        return (run, longest)
    }
}
