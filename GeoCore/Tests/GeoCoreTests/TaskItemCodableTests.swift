import Foundation
import XCTest
@testable import GeoCore

final class TaskItemCodableTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func testTaskItemCodableRoundTripsEveryBodyKind() throws {
        let createdAt = date(2025, 1, 2, 9, 30)
        let modifiedAt = date(2025, 1, 3, 10, 45)
        let reminderDate = date(2025, 1, 2, 8, 0)
        let reminders = [
            Reminder(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                trigger: .offset(.fifteenMinutes),
                fired: false
            ),
            Reminder(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                trigger: .absolute(reminderDate),
                fired: true
            )
        ]
        let bodies: [TaskBody] = [
            .task(due: date(2025, 2, 10, 14, 0), estimatedMinutes: 45),
            .event(
                start: date(2025, 3, 11, 16, 0),
                end: date(2025, 3, 11, 17, 30),
                externalEKEventID: "event-42"
            ),
            .habit(
                rule: .weekly(on: [2, 4, 6], until: date(2025, 12, 31, 23, 59)),
                timeOfDay: date(2025, 4, 1, 7, 15),
                occurrences: [date(2025, 4, 2, 7, 15), date(2025, 4, 4, 7, 15)]
            ),
            .milestone(target: date(2025, 6, 30, 18, 0))
        ]

        for (index, body) in bodies.enumerated() {
            let item = TaskItem(
                id: "item-\(index)",
                title: "Fixture \(index)",
                linkedBlockId: "block-\(index)",
                status: index.isMultiple(of: 2) ? .pending : .completed,
                priority: [.urgent, .high, .medium, .low][index],
                tagIds: ["tag-a", "tag-b"],
                orderIndex: index,
                estimatedMinutes: 30 + index,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                body: body,
                reminders: reminders,
                externalEKEventID: body.kind == .event ? "top-level-event" : nil,
                isAllDay: index == 3
            )

            let data = try JSONEncoder().encode(item)
            let decoded = try JSONDecoder().decode(TaskItem.self, from: data)

            assertEqual(decoded, item)
        }
    }

    func testEnumsCodableRoundTrip() throws {
        try assertCodableRoundTrip(TaskStatus.allCases)
        try assertCodableRoundTrip(TaskKind.allCases)
        try assertCodableRoundTrip(TaskPriority.allCases)
        try assertCodableRoundTrip(RecurrenceFrequency.allCases)
        try assertCodableRoundTrip(ReminderOffset.allCases)
        try assertCodableRoundTrip([
            RecurrenceRule.RuleType.never,
            .daily,
            .weekdays,
            .weekly,
            .biweekly,
            .monthly,
            .yearly,
            .custom
        ])
    }

    func testReminderAndTriggersCodableAndFireDates() throws {
        let anchor = date(2025, 5, 20, 12, 0)
        let absoluteDate = date(2025, 5, 19, 8, 30)
        let offsetReminder = Reminder(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            trigger: .offset(.oneHour),
            fired: false
        )
        let absoluteReminder = Reminder(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
            trigger: .absolute(absoluteDate),
            fired: true
        )

        let offsetDecoded = try roundTrip(offsetReminder)
        let absoluteDecoded = try roundTrip(absoluteReminder)

        XCTAssertEqual(offsetDecoded, offsetReminder)
        XCTAssertEqual(absoluteDecoded, absoluteReminder)
        XCTAssertEqual(offsetDecoded.fireDate(forAnchor: anchor), date(2025, 5, 20, 11, 0))
        XCTAssertEqual(absoluteDecoded.fireDate(forAnchor: anchor), absoluteDate)
    }

    func testDailyRecurrenceNextDate() {
        let start = date(2025, 1, 15, 9, 45)

        XCTAssertEqual(
            RecurrenceRule.daily.nextDate(after: start, calendar: calendar),
            date(2025, 1, 16, 9, 45)
        )
    }

    func testWeekdaysRecurrenceSkipsWeekend() {
        let friday = date(2025, 1, 17, 18, 20)

        XCTAssertEqual(
            RecurrenceRule.weekdays.nextDate(after: friday, calendar: calendar),
            date(2025, 1, 20, 18, 20)
        )
    }

    func testCustomRecurrenceUsesFixedInterval() {
        let start = date(2025, 1, 31, 6, 10)
        let rule = RecurrenceRule.custom(every: 3, frequency: .daily)

        XCTAssertEqual(
            rule.nextDate(after: start, calendar: calendar),
            date(2025, 2, 3, 6, 10)
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func assertCodableRoundTrip<Value: Codable & Equatable>(_ values: [Value]) throws {
        for value in values {
            XCTAssertEqual(try roundTrip(value), value)
        }
    }

    private func assertEqual(
        _ decoded: TaskItem,
        _ original: TaskItem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(decoded.id, original.id, file: file, line: line)
        XCTAssertEqual(decoded.title, original.title, file: file, line: line)
        XCTAssertEqual(decoded.linkedBlockId, original.linkedBlockId, file: file, line: line)
        XCTAssertEqual(decoded.status, original.status, file: file, line: line)
        XCTAssertEqual(decoded.priority, original.priority, file: file, line: line)
        XCTAssertEqual(decoded.tagIds, original.tagIds, file: file, line: line)
        XCTAssertEqual(decoded.orderIndex, original.orderIndex, file: file, line: line)
        XCTAssertEqual(decoded.estimatedMinutes, original.estimatedMinutes, file: file, line: line)
        XCTAssertEqual(decoded.createdAt, original.createdAt, file: file, line: line)
        XCTAssertEqual(decoded.modifiedAt, original.modifiedAt, file: file, line: line)
        XCTAssertEqual(decoded.body, original.body, file: file, line: line)
        XCTAssertEqual(decoded.reminders, original.reminders, file: file, line: line)
        XCTAssertEqual(decoded.externalEKEventID, original.externalEKEventID, file: file, line: line)
        XCTAssertEqual(decoded.isAllDay, original.isAllDay, file: file, line: line)
    }
}
