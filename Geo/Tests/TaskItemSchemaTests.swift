import XCTest
@testable import Geo

final class TaskItemSchemaTests: XCTestCase {

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testRoundTripPreservesExplicitNewFields() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let timeOfDay = Date(timeIntervalSince1970: 1_700_025_200)
        let snapshotDate = Date(timeIntervalSince1970: 1_699_900_000)

        let snapshots = [
            CheckboxSnapshot(text: "Stretch", wasChecked: true),
            CheckboxSnapshot(text: "Read", wasChecked: false)
        ]
        let occurrence = HabitOccurrence(date: snapshotDate, checkboxes: snapshots)
        let habit = HabitState(
            occurrences: [occurrence],
            currentStreak: 3,
            longestStreak: 7,
            resetCheckboxesOnComplete: true
        )
        let alerts = ScheduleAlerts(
            reminders: [.fiveMinutes],
            recurringReminders: [],
            firedReminders: [.atTime],
            smartReminder: true,
            snoozedUntil: snapshotDate
        )
        let schedule = Schedule.recurring(rule: .daily, timeOfDay: timeOfDay)

        let task = TaskItem(
            id: "abc",
            title: "Morning Routine",
            notes: "",
            linkedBlockId: "blk-1",
            status: .pending,
            startTime: start,
            endTime: nil,
            reminders: [.fiveMinutes],
            recurringReminders: [],
            recurrence: .daily,
            firedReminders: [.atTime],
            orderIndex: 2,
            smartReminder: true,
            snoozedUntil: snapshotDate,
            createdAt: start,
            modifiedAt: start,
            kind: .habit,
            priority: .high,
            tagIds: ["t1"],
            parentId: nil,
            estimatedMinutes: 15,
            context: nil,
            completionHistory: [snapshotDate],
            currentStreak: 3,
            longestStreak: 7,
            schedule: schedule,
            scheduleAlerts: alerts,
            habitState: habit
        )

        let data = try makeEncoder().encode(task)
        let decoded = try makeDecoder().decode(TaskItem.self, from: data)

        XCTAssertEqual(decoded.schedule, schedule)
        XCTAssertEqual(decoded.scheduleAlerts, alerts)
        XCTAssertEqual(decoded.habitState, habit)
        XCTAssertEqual(decoded.habitState?.occurrences.first?.checkboxes, snapshots)
    }

    func testEncodeThenDecodeProducesEqualStruct() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let task = TaskItem(
            id: "round-trip",
            title: "Plan week",
            startTime: start,
            createdAt: start,
            modifiedAt: start,
            kind: .task,
            priority: .medium
        )

        let data = try makeEncoder().encode(task)
        let decoded = try makeDecoder().decode(TaskItem.self, from: data)

        XCTAssertEqual(decoded, task)
    }

    func testDecodeLegacyJsonPopulatesNewFieldsForMilestone() throws {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let json = legacyJSON(
            id: "m1",
            title: "Ship v2",
            kind: "milestone",
            startTime: start,
            endTime: nil,
            recurrenceType: "never"
        )

        let decoded = try makeDecoder().decode(TaskItem.self, from: json)

        XCTAssertEqual(decoded.schedule, .targeting(start))
        XCTAssertEqual(decoded.scheduleAlerts.reminders, [.atTime])
        XCTAssertNil(decoded.habitState)
    }

    func testDecodeLegacyJsonPopulatesNewFieldsForEventWithEndTime() throws {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let end = start.addingTimeInterval(3600)
        let json = legacyJSON(
            id: "e1",
            title: "Standup",
            kind: "event",
            startTime: start,
            endTime: end,
            recurrenceType: "never"
        )

        let decoded = try makeDecoder().decode(TaskItem.self, from: json)

        XCTAssertEqual(decoded.schedule, .at(start, duration: end.timeIntervalSince(start)))
        XCTAssertNil(decoded.habitState)
    }

    func testDecodeLegacyJsonPopulatesNewFieldsForHabit() throws {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let completionA = Date(timeIntervalSince1970: 1_709_900_000)
        let completionB = Date(timeIntervalSince1970: 1_709_990_000)
        let json = legacyJSON(
            id: "h1",
            title: "Stretch",
            kind: "habit",
            startTime: start,
            endTime: nil,
            recurrenceType: "daily",
            completionHistory: [completionA, completionB],
            currentStreak: 2,
            longestStreak: 4
        )

        let decoded = try makeDecoder().decode(TaskItem.self, from: json)

        guard case .recurring(let rule, let timeOfDay) = decoded.schedule else {
            XCTFail("Expected .recurring schedule")
            return
        }
        XCTAssertEqual(rule, .daily)
        XCTAssertEqual(timeOfDay, start)
        XCTAssertEqual(decoded.habitState?.currentStreak, 2)
        XCTAssertEqual(decoded.habitState?.longestStreak, 4)
        XCTAssertEqual(decoded.habitState?.completionHistory, [completionA, completionB])
        XCTAssertEqual(decoded.habitState?.resetCheckboxesOnComplete, true)
    }

    func testDecodeLegacyJsonPopulatesNewFieldsForTaskDueBy() throws {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let json = legacyJSON(
            id: "t1",
            title: "Buy milk",
            kind: "task",
            startTime: start,
            endTime: nil,
            recurrenceType: "never"
        )

        let decoded = try makeDecoder().decode(TaskItem.self, from: json)

        XCTAssertEqual(decoded.schedule, .dueBy(start))
        XCTAssertNil(decoded.habitState)
    }

    func testHabitCompletionHistoryRoundTripsThroughHabitState() throws {
        let dates = [
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_700_086_400)
        ]
        let task = TaskItem(
            id: "h2",
            title: "Daily walk",
            startTime: Date(timeIntervalSince1970: 1_700_172_800),
            recurrence: .daily,
            kind: .habit,
            completionHistory: dates,
            currentStreak: 2,
            longestStreak: 5
        )

        XCTAssertEqual(task.habitState?.completionHistory, dates)

        let data = try makeEncoder().encode(task)
        let decoded = try makeDecoder().decode(TaskItem.self, from: data)
        XCTAssertEqual(decoded.habitState?.completionHistory, dates)
        XCTAssertEqual(decoded.habitState?.currentStreak, 2)
        XCTAssertEqual(decoded.habitState?.longestStreak, 5)
    }

    func testMilestoneInitProducesTargetingSchedule() {
        let target = Date(timeIntervalSince1970: 1_720_000_000)
        let task = TaskItem(
            id: "m2",
            title: "Launch",
            startTime: target,
            kind: .milestone
        )

        XCTAssertEqual(task.schedule, .targeting(target))
    }

    func testEventWithEndTimeInitProducesAtSchedule() {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let end = start.addingTimeInterval(1800)
        let task = TaskItem(
            id: "e2",
            title: "Sync",
            startTime: start,
            endTime: end,
            kind: .event
        )

        XCTAssertEqual(task.schedule, .at(start, duration: end.timeIntervalSince(start)))
    }

    func testEncoderWritesBothLegacyAndNewKeys() throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let task = TaskItem(
            id: "dual",
            title: "Dual write",
            startTime: start,
            kind: .task
        )

        let data = try makeEncoder().encode(task)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["startTime"], "legacy startTime should still be encoded")
        XCTAssertNotNil(json["recurrence"], "legacy recurrence should still be encoded")
        XCTAssertNotNil(json["schedule"], "new schedule should be encoded")
        XCTAssertNotNil(json["scheduleAlerts"], "new scheduleAlerts should be encoded")
    }

    private func legacyJSON(
        id: String,
        title: String,
        kind: String,
        startTime: Date,
        endTime: Date?,
        recurrenceType: String,
        completionHistory: [Date] = [],
        currentStreak: Int = 0,
        longestStreak: Int = 0
    ) -> Data {
        let isoFormatter = ISO8601DateFormatter()
        var fields: [String] = []
        fields.append("\"id\":\"\(id)\"")
        fields.append("\"title\":\"\(title)\"")
        fields.append("\"notes\":\"\"")
        fields.append("\"status\":\"pending\"")
        fields.append("\"startTime\":\"\(isoFormatter.string(from: startTime))\"")
        if let endTime {
            fields.append("\"endTime\":\"\(isoFormatter.string(from: endTime))\"")
        }
        fields.append("\"reminders\":[\"At time\"]")
        fields.append("\"recurringReminders\":[]")
        fields.append("\"recurrence\":{\"type\":\"\(recurrenceType)\"}")
        fields.append("\"firedReminders\":[]")
        fields.append("\"orderIndex\":0")
        fields.append("\"smartReminder\":false")
        fields.append("\"createdAt\":\"\(isoFormatter.string(from: startTime))\"")
        fields.append("\"modifiedAt\":\"\(isoFormatter.string(from: startTime))\"")
        fields.append("\"kind\":\"\(kind)\"")
        fields.append("\"priority\":\"unset\"")
        fields.append("\"tagIds\":[]")
        let history = completionHistory.map { "\"\(isoFormatter.string(from: $0))\"" }.joined(separator: ",")
        fields.append("\"completionHistory\":[\(history)]")
        fields.append("\"currentStreak\":\(currentStreak)")
        fields.append("\"longestStreak\":\(longestStreak)")
        let body = "{" + fields.joined(separator: ",") + "}"
        return body.data(using: .utf8)!
    }
}
