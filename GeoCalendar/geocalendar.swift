import CoreGraphics
import EventKit
import Foundation

func logErr(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
}

let fm = FileManager.default
let tasksDir = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("Vault", isDirectory: true)
    .appendingPathComponent("Tasks", isDirectory: true)
let stateDir = fm.homeDirectoryForCurrentUser
    .appendingPathComponent(".hermes", isDirectory: true)
    .appendingPathComponent("state", isDirectory: true)
let stateURL = stateDir.appendingPathComponent("geocalendar.json", isDirectory: false)

let pollInterval: TimeInterval = 60

enum TaskStatus: String, Codable {
    case pending
    case completed
}

enum TaskKind: String, Codable {
    case task, event, habit, milestone
}

struct RecurrenceRule: Codable {
    enum RuleType: String, Codable {
        case never, daily, weekdays, weekly, biweekly, monthly, yearly, custom
    }
    enum Frequency: String, Codable {
        case daily = "Day", weekly = "Week", monthly = "Month", yearly = "Year"
    }
    var type: RuleType
    var customFrequency: Frequency?
    var customInterval: Int?
    var endDate: Date?
    var selectedWeekdays: [Int]?

    func toEKRecurrenceRule() -> EKRecurrenceRule? {
        let end = endDate.map { EKRecurrenceEnd(end: $0) }

        func daysOfWeek(_ weekdays: [Int]?) -> [EKRecurrenceDayOfWeek]? {
            guard let weekdays, !weekdays.isEmpty else { return nil }
            let mapped = weekdays.compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } }
            return mapped.isEmpty ? nil : mapped
        }

        func rule(_ freq: EKRecurrenceFrequency, _ interval: Int, days: [EKRecurrenceDayOfWeek]? = nil) -> EKRecurrenceRule {
            EKRecurrenceRule(
                recurrenceWith: freq,
                interval: max(1, interval),
                daysOfTheWeek: days,
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: end
            )
        }

        switch type {
        case .never:
            return nil
        case .daily:
            return rule(.daily, 1)
        case .weekdays:
            let weekdays: [EKRecurrenceDayOfWeek] = [.monday, .tuesday, .wednesday, .thursday, .friday]
                .map { EKRecurrenceDayOfWeek($0) }
            return rule(.weekly, 1, days: weekdays)
        case .weekly:
            return rule(.weekly, 1, days: daysOfWeek(selectedWeekdays))
        case .biweekly:
            return rule(.weekly, 2, days: daysOfWeek(selectedWeekdays))
        case .monthly:
            return rule(.monthly, 1)
        case .yearly:
            return rule(.yearly, 1)
        case .custom:
            let interval = max(1, customInterval ?? 1)
            let freq: EKRecurrenceFrequency
            switch customFrequency ?? .daily {
            case .daily: freq = .daily
            case .weekly: freq = .weekly
            case .monthly: freq = .monthly
            case .yearly: freq = .yearly
            }
            return rule(freq, interval)
        }
    }
}

struct TaskBody: Codable {
    var kind: TaskKind
    var due: Date?
    var start: Date?
    var end: Date?
    var rule: RecurrenceRule?
    var timeOfDay: Date?
    var occurrences: [Date]?
    var target: Date?

    var anchorDate: Date {
        switch kind {
        case .task: return due ?? Date()
        case .event: return start ?? Date()
        case .habit: return timeOfDay ?? Date()
        case .milestone: return target ?? Date()
        }
    }
}

struct TaskItem: Codable {
    let id: String
    var title: String
    var status: TaskStatus
    var priority: String
    var tagIds: [String]
    var orderIndex: Int
    var estimatedMinutes: Int?
    let createdAt: Date
    var modifiedAt: Date
    var body: TaskBody
    var reminders: [JSONValueSink]?
    var externalEKEventID: String?
    var isAllDay: Bool?

    var resolvedIsAllDay: Bool {
        if let isAllDay { return isAllDay }
        let c = Calendar.current.dateComponents([.hour, .minute], from: body.anchorDate)
        return (c.hour == 0 && c.minute == 0) || (c.hour == 23 && c.minute == 59)
    }
}

struct JSONValueSink: Codable {
    init(from decoder: Decoder) throws {}
    func encode(to encoder: Encoder) throws {}
}

struct EventMirrorPlan {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var recurrenceRules: [EKRecurrenceRule]
}

func mirrorPlan(for task: TaskItem) -> EventMirrorPlan {
    let calendar = Calendar.current
    let title = task.status == .completed ? "✓ \(task.title)" : task.title
    let allDay = task.resolvedIsAllDay

    func plan(forAnchor anchor: Date, recurrenceRules: [EKRecurrenceRule] = []) -> EventMirrorPlan {
        if allDay {
            let dayStart = calendar.startOfDay(for: anchor)
            return EventMirrorPlan(title: title, start: dayStart, end: dayStart, isAllDay: true, recurrenceRules: recurrenceRules)
        }
        return EventMirrorPlan(title: title, start: anchor, end: anchor.addingTimeInterval(3600), isAllDay: false, recurrenceRules: recurrenceRules)
    }

    switch task.body.kind {
    case .event:
        let start = task.body.start ?? Date()
        let end = max(task.body.end ?? start, start)
        if allDay {
            let dayStart = calendar.startOfDay(for: start)
            return EventMirrorPlan(title: title, start: dayStart, end: dayStart, isAllDay: true, recurrenceRules: [])
        }
        return EventMirrorPlan(title: title, start: start, end: end, isAllDay: false, recurrenceRules: [])
    case .habit:
        let anchor = task.body.timeOfDay ?? Date()
        let rules = task.body.rule?.toEKRecurrenceRule().map { [$0] } ?? []
        return plan(forAnchor: anchor, recurrenceRules: rules)
    case .task:
        return plan(forAnchor: task.body.due ?? Date())
    case .milestone:
        return plan(forAnchor: task.body.target ?? Date())
    }
}

let poolColors: [CGColor] = [
    CGColor(srgbRed: 1.00, green: 0.231, blue: 0.188, alpha: 1),
    CGColor(srgbRed: 1.00, green: 0.584, blue: 0.00, alpha: 1),
    CGColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1),
    CGColor(srgbRed: 0.188, green: 0.690, blue: 0.780, alpha: 1),
    CGColor(srgbRed: 0.00, green: 0.478, blue: 1.00, alpha: 1),
    CGColor(srgbRed: 0.686, green: 0.322, blue: 0.871, alpha: 1),
]

func poolIndex(for id: String) -> Int {
    var h: UInt64 = 5381
    for b in id.utf8 { h = (h &* 33) &+ UInt64(b) }
    return Int(h % UInt64(poolColors.count))
}

final class CalendarPool {
    let store: EKEventStore
    private var cache: [Int: EKCalendar] = [:]
    private let creationLock = NSLock()

    init(store: EKEventStore) {
        self.store = store
    }

    private var preferredEventSource: EKSource? {
        store.sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" })
            ?? store.defaultCalendarForNewEvents?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first
    }

    func calendar(forTaskID id: String) -> EKCalendar? {
        let index = poolIndex(for: id)
        if let cached = cache[index] { return cached }
        creationLock.lock()
        defer { creationLock.unlock() }
        if let cached = cache[index] { return cached }
        let title = "Geo · \(index + 1)"
        if let existing = store.calendars(for: .event).first(where: { $0.title == title }) {
            cache[index] = existing
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = title
        cal.cgColor = poolColors[index]
        cal.source = preferredEventSource
        do {
            try store.saveCalendar(cal, commit: true)
            cache[index] = cal
            return cal
        } catch {
            logErr("failed to save calendar \(title): \(error.localizedDescription)")
            return nil
        }
    }
}

func configure(_ event: EKEvent, with plan: EventMirrorPlan, calendar: EKCalendar) {
    event.title = plan.title
    event.isAllDay = plan.isAllDay
    event.startDate = plan.start
    event.endDate = plan.end
    event.url = nil
    event.notes = nil
    event.calendar = calendar
    for existing in event.recurrenceRules ?? [] {
        event.removeRecurrenceRule(existing)
    }
    for rule in plan.recurrenceRules {
        event.addRecurrenceRule(rule)
    }
}

func recurringEventMatches(_ event: EKEvent, plan: EventMirrorPlan) -> Bool {
    guard event.isAllDay == plan.isAllDay, event.title == plan.title else { return false }
    let cal = Calendar.current
    guard cal.dateComponents([.hour, .minute], from: event.startDate) ==
        cal.dateComponents([.hour, .minute], from: plan.start) else { return false }
    let evRule = event.recurrenceRules?.first
    let planRule = plan.recurrenceRules.first
    return evRule?.frequency == planRule?.frequency && evRule?.interval == planRule?.interval
}

func eventMatches(_ event: EKEvent, plan: EventMirrorPlan) -> Bool {
    guard plan.recurrenceRules.isEmpty else { return recurringEventMatches(event, plan: plan) }
    return event.title == plan.title
        && event.isAllDay == plan.isAllDay
        && event.startDate == plan.start
        && event.endDate == plan.end
        && (event.recurrenceRules?.isEmpty ?? true)
}

func findCandidates(plan: EventMirrorPlan, calendar: EKCalendar, store: EKEventStore) -> [EKEvent] {
    let cal = Calendar.current
    let windowStart = cal.date(byAdding: .day, value: -1, to: plan.start) ?? plan.start
    let windowEnd = cal.date(byAdding: .day, value: 2, to: plan.start) ?? plan.start
    let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [calendar])
    return store.events(matching: predicate).filter { event in
        guard event.title == plan.title, event.isAllDay == plan.isAllDay else { return false }
        if plan.isAllDay {
            return cal.isDate(event.startDate, inSameDayAs: plan.start)
        }
        return event.startDate == plan.start
    }
}

func findRecurringCandidates(plan: EventMirrorPlan, calendar: EKCalendar, store: EKEventStore) -> [EKEvent] {
    let cal = Calendar.current
    let windowStart = cal.date(byAdding: .day, value: -400, to: Date()) ?? Date()
    let windowEnd = cal.date(byAdding: .day, value: 400, to: Date()) ?? Date()
    let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [calendar])
    var seen = Set<String>()
    var result: [EKEvent] = []
    for event in store.events(matching: predicate) {
        guard event.title == plan.title, !(event.recurrenceRules?.isEmpty ?? true) else { continue }
        guard seen.insert(event.eventIdentifier).inserted else { continue }
        result.append(event)
    }
    return result
}

func mirror(task: TaskItem, store: EKEventStore, pool: CalendarPool) -> String? {
    let plan = mirrorPlan(for: task)
    guard let calendar = pool.calendar(forTaskID: task.id) else { return task.externalEKEventID }
    do {
        let existing = task.externalEKEventID.flatMap { store.event(withIdentifier: $0) }

        if !plan.recurrenceRules.isEmpty {
            var candidates = findRecurringCandidates(plan: plan, calendar: calendar, store: store)
            if let existing, !candidates.contains(where: { $0.eventIdentifier == existing.eventIdentifier }) {
                candidates.append(existing)
            }
            if !candidates.isEmpty {
                let sorted = candidates.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                let winner = sorted[0]
                for dup in sorted.dropFirst() {
                    try? store.remove(dup, span: .futureEvents, commit: false)
                }
                if sorted.count > 1 {
                    try store.commit()
                }
                if recurringEventMatches(winner, plan: plan) { return winner.eventIdentifier }
                try? store.remove(winner, span: .futureEvents, commit: false)
                return try createEvent(plan, calendar: calendar, store: store)
            }
            if let existing { try? store.remove(existing, span: .futureEvents, commit: false) }
            return try createEvent(plan, calendar: calendar, store: store)
        }

        let candidates = findCandidates(plan: plan, calendar: calendar, store: store)
        if !candidates.isEmpty {
            let sorted = candidates.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            let winner = sorted[0]
            for dup in sorted.dropFirst() {
                try? store.remove(dup, span: .thisEvent, commit: false)
            }
            if sorted.count > 1 {
                try store.commit()
            }
            if !eventMatches(winner, plan: plan) {
                configure(winner, with: plan, calendar: calendar)
                try store.save(winner, span: .thisEvent, commit: true)
            }
            return winner.eventIdentifier
        }

        if let existing {
            configure(existing, with: plan, calendar: calendar)
            try store.save(existing, span: .thisEvent, commit: true)
            return existing.eventIdentifier
        }

        return try createEvent(plan, calendar: calendar, store: store)
    } catch {
        logErr("mirror failed for task \(task.id): \(error.localizedDescription)")
        return task.externalEKEventID
    }
}

func createEvent(_ plan: EventMirrorPlan, calendar: EKCalendar, store: EKEventStore) throws -> String {
    let event = EKEvent(eventStore: store)
    configure(event, with: plan, calendar: calendar)
    let span: EKSpan = plan.recurrenceRules.isEmpty ? .thisEvent : .futureEvents
    try store.save(event, span: span, commit: true)
    return event.eventIdentifier
}

func removeMirror(eventID: String, store: EKEventStore) {
    guard let event = store.event(withIdentifier: eventID) else { return }
    let span: EKSpan = (event.recurrenceRules?.isEmpty == false) ? .futureEvents : .thisEvent
    try? store.remove(event, span: span, commit: true)
}

let iso8601 = ISO8601DateFormatter()

func loadTasks() -> [TaskItem] {
    guard let urls = try? fm.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var results: [TaskItem] = []
    for url in urls where url.pathExtension == "json" {
        guard let data = try? Data(contentsOf: url),
              let task = try? decoder.decode(TaskItem.self, from: data) else { continue }
        results.append(task)
    }
    return results
}

func writeBackEventID(taskID: String, eventID: String) {
    let url = tasksDir.appendingPathComponent("\(taskID).json")
    guard var data = try? Data(contentsOf: url),
          var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    obj["externalEKEventID"] = eventID
    guard let updated = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
    data = updated
    try? data.write(to: url, options: .atomic)
}

func loadState() -> [String: String] {
    guard let data = try? Data(contentsOf: stateURL),
          let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
    return dict
}

func saveState(_ state: [String: String]) {
    try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: stateURL, options: .atomic)
}

func requestAccess(store: EKEventStore) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    store.requestFullAccessToEvents { ok, error in
        granted = ok
        if let error {
            logErr("requestFullAccessToEvents error: \(error.localizedDescription)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    return granted
}

func sweepUntrackedPoolEvents(store: EKEventStore, trackedEventIDs: Set<String>) {
    let cal = Calendar.current
    let windowStart = cal.date(byAdding: .day, value: -400, to: Date()) ?? Date()
    let windowEnd = cal.date(byAdding: .day, value: 400, to: Date()) ?? Date()
    let poolCalendars = store.calendars(for: .event).filter { $0.title.hasPrefix("Geo · ") }
    var removedAny = false
    for calendar in poolCalendars {
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [calendar])
        var seen = Set<String>()
        for event in store.events(matching: predicate) {
            guard seen.insert(event.eventIdentifier).inserted else { continue }
            guard !trackedEventIDs.contains(event.eventIdentifier) else { continue }
            let span: EKSpan = (event.recurrenceRules?.isEmpty == false) ? .futureEvents : .thisEvent
            try? store.remove(event, span: span, commit: false)
            removedAny = true
        }
    }
    if removedAny {
        try? store.commit()
    }
}

func syncOnce(store: EKEventStore, pool: CalendarPool) {
    let tasks = loadTasks()
    var state = loadState()
    var seenTaskIDs = Set<String>()

    for task in tasks {
        seenTaskIDs.insert(task.id)
        let newID = mirror(task: task, store: store, pool: pool)
        if let newID, newID != task.externalEKEventID {
            writeBackEventID(taskID: task.id, eventID: newID)
        }
        if let newID {
            state[task.id] = newID
        }
    }

    for (taskID, eventID) in state where !seenTaskIDs.contains(taskID) {
        removeMirror(eventID: eventID, store: store)
        state.removeValue(forKey: taskID)
    }

    saveState(state)
    sweepUntrackedPoolEvents(store: store, trackedEventIDs: Set(state.values))
}

let store = EKEventStore()
guard requestAccess(store: store) else {
    logErr("Calendar access not granted; exiting so KeepAlive can retry after the user approves TCC")
    exit(1)
}

let pool = CalendarPool(store: store)
logErr("geocalendar started, polling \(tasksDir.path) every \(Int(pollInterval))s")

while true {
    syncOnce(store: store, pool: pool)
    Thread.sleep(forTimeInterval: pollInterval)
}
