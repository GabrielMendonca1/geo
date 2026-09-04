import Foundation

public struct CalendarMirrorEntry: Hashable, Sendable {
    public let taskId: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool

    public init(taskId: String, title: String, start: Date, end: Date, isAllDay: Bool) {
        self.taskId = taskId
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }

    public var notes: String { CalendarMirror.marker(for: taskId) }

    public var signature: String {
        [
            taskId,
            title,
            String(start.timeIntervalSinceReferenceDate),
            String(end.timeIntervalSinceReferenceDate),
            String(isAllDay)
        ].joined(separator: "|")
    }
}

public struct CalendarMirrorEvent: Hashable, Sendable {
    public let eventId: String
    public let taskId: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool

    public init(eventId: String, taskId: String, title: String, start: Date, end: Date, isAllDay: Bool) {
        self.eventId = eventId
        self.taskId = taskId
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }
}

public enum CalendarMirrorAction: Hashable, Sendable {
    case create(CalendarMirrorEntry)
    case update(eventId: String, entry: CalendarMirrorEntry)
    case delete(eventId: String)

    public var signature: String {
        switch self {
        case .create(let entry): return "create|" + entry.signature
        case .update(let eventId, let entry): return "update|" + eventId + "|" + entry.signature
        case .delete(let eventId): return "delete|" + eventId
        }
    }
}

public enum CalendarMirror {
    public static let calendarTitle = "Garime"
    public static let untitledFallback = "Sem título"
    public static let minimumDuration: TimeInterval = 60

    private static let markerOpen = "[Garime:"
    private static let markerClose = "]"

    public static func marker(for taskId: String) -> String {
        markerOpen + taskId + markerClose
    }

    public static func taskId(inNotes notes: String?) -> String? {
        guard let notes else { return nil }
        guard let open = notes.range(of: markerOpen) else { return nil }
        guard let close = notes.range(of: markerClose, range: open.upperBound..<notes.endIndex) else { return nil }
        let taskId = String(notes[open.upperBound..<close.lowerBound])
        return taskId.isEmpty ? nil : taskId
    }

    public static func isMirrored(notes: String?) -> Bool {
        taskId(inNotes: notes) != nil
    }

    public static func entry(for task: TaskItem) -> CalendarMirrorEntry? {
        guard task.status == .pending else { return nil }
        guard case .event(let start, let end, _) = task.body else { return nil }
        let trimmed = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAllDay = task.resolvedIsAllDay
        let floor = isAllDay ? start : start.addingTimeInterval(minimumDuration)
        return CalendarMirrorEntry(
            taskId: task.id,
            title: trimmed.isEmpty ? untitledFallback : trimmed,
            start: start,
            end: max(end, floor),
            isAllDay: isAllDay
        )
    }

    public static func desiredEntries(for tasks: [TaskItem], in window: DateInterval? = nil) -> [CalendarMirrorEntry] {
        var seen = Set<String>()
        var entries: [CalendarMirrorEntry] = []
        for task in tasks {
            guard let entry = entry(for: task) else { continue }
            if let window, !overlaps(entry: entry, window: window) { continue }
            guard seen.insert(entry.taskId).inserted else { continue }
            entries.append(entry)
        }
        return entries
    }

    public static func plan(
        tasks: [TaskItem],
        existing: [CalendarMirrorEvent],
        in window: DateInterval? = nil,
        calendar: Calendar = .current
    ) -> [CalendarMirrorAction] {
        var canonical: [String: CalendarMirrorEvent] = [:]
        var stale: [CalendarMirrorEvent] = []
        for event in existing.sorted(by: { $0.eventId < $1.eventId }) {
            if canonical[event.taskId] == nil {
                canonical[event.taskId] = event
            } else {
                stale.append(event)
            }
        }

        var actions: [CalendarMirrorAction] = []
        var wanted = Set<String>()
        for entry in desiredEntries(for: tasks, in: window) {
            wanted.insert(entry.taskId)
            guard let match = canonical[entry.taskId] else {
                actions.append(.create(entry))
                continue
            }
            if !isUpToDate(match, entry: entry, calendar: calendar) {
                actions.append(.update(eventId: match.eventId, entry: entry))
            }
        }

        let orphans = canonical.values.filter { !wanted.contains($0.taskId) }
        let removals = (stale + orphans).map(\.eventId).sorted()
        actions.append(contentsOf: removals.map { CalendarMirrorAction.delete(eventId: $0) })
        return actions
    }

    public static func signature(for actions: [CalendarMirrorAction]) -> String {
        actions.map(\.signature).joined(separator: "\n")
    }

    static func overlaps(entry: CalendarMirrorEntry, window: DateInterval) -> Bool {
        entry.end > window.start && entry.start < window.end
    }

    static func isUpToDate(_ event: CalendarMirrorEvent, entry: CalendarMirrorEntry, calendar: Calendar) -> Bool {
        guard event.title == entry.title, event.isAllDay == entry.isAllDay else { return false }
        if entry.isAllDay {
            return calendar.isDate(event.start, inSameDayAs: entry.start)
                && calendar.isDate(event.end, inSameDayAs: entry.end)
        }
        return sameInstant(event.start, entry.start) && sameInstant(event.end, entry.end)
    }

    static func sameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 1
    }
}
