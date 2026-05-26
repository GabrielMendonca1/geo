import SwiftUI

enum CalendarEventType: Hashable {
    case task(TaskItem)
    case block(BlockEntity)
    case holiday(Holiday)
}

struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date?
    let type: CalendarEventType
    let color: Color

    var isMultiDay: Bool {
        guard let endDate else { return false }
        return !Calendar.current.isDate(startDate, inSameDayAs: endDate)
    }

    var durationInDays: Int {
        guard let endDate else { return 1 }
        let days = Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        return max(1, days + 1)
    }

    static func from(task: TaskItem, occurrenceSuffix: String? = nil, blocksById: [String: BlockEntity], tagsById: [String: Tag]) -> CalendarEvent {
        let id = occurrenceSuffix.map { "task-\(task.id)-\($0)" } ?? "task-\(task.id)"
        return CalendarEvent(
            id: id,
            title: task.title,
            startDate: task.startTime,
            endDate: task.endTime,
            type: .task(task),
            color: resolvedColor(for: task, blocksById: blocksById, tagsById: tagsById)
        )
    }

    static func from(task: TaskItem, occurrenceDate: Date, blocksById: [String: BlockEntity], tagsById: [String: Tag]) -> CalendarEvent {
        let duration = task.endTime.map { $0.timeIntervalSince(task.startTime) }
        var shifted = task
        shifted.startTime = occurrenceDate
        shifted.endTime = duration.map { occurrenceDate.addingTimeInterval($0) }
        let suffix = "\(Int(occurrenceDate.timeIntervalSinceReferenceDate))"
        return from(task: shifted, occurrenceSuffix: suffix, blocksById: blocksById, tagsById: tagsById)
    }

    static func from(block: BlockEntity, tagsById: [String: Tag]) -> CalendarEvent {
        CalendarEvent(
            id: "block-\(block.id)",
            title: block.displayTitle,
            startDate: block.date,
            endDate: nil,
            type: .block(block),
            color: resolvedColor(for: block, tagsById: tagsById)
        )
    }

    static func from(holiday: Holiday) -> CalendarEvent {
        CalendarEvent(
            id: "holiday-\(holiday.id)",
            title: holiday.name,
            startDate: holiday.startDate,
            endDate: holiday.endDate,
            type: .holiday(holiday),
            color: GeoStyle.Colors.EventPill.holiday
        )
    }

    private static func resolvedColor(for task: TaskItem, blocksById: [String: BlockEntity], tagsById: [String: Tag]) -> Color {
        if let blockId = task.linkedBlockId, let block = blocksById[blockId] {
            return resolvedColor(for: block, tagsById: tagsById)
        }
        return stableColor(for: task.id)
    }

    private static func resolvedColor(for block: BlockEntity, tagsById: [String: Tag]) -> Color {
        if let tagColor = resolvedTagColor(for: block, tagsById: tagsById) {
            return tagColor
        }
        return stableColor(for: block.id)
    }

    private static func resolvedTagColor(for block: BlockEntity, tagsById: [String: Tag]) -> Color? {
        let tagId = block.tagId ?? block.metadata.tagId
        guard let tagId else { return nil }
        return tagsById[tagId]?.color.swiftUIColor
    }

    private static func stableColor(for id: String) -> Color {
        let palette = GeoStyle.Colors.EventPill.palette
        guard !palette.isEmpty else { return GeoStyle.Colors.EventPill.reminderDefault }
        let hash = stableHash(id)
        let index = Int(hash % UInt64(palette.count))
        return palette[index]
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }
}
