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

    func testHabitRoundTripPreservesBodyAndFields() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let timeOfDay = Date(timeIntervalSince1970: 1_700_025_200)
        let occurrenceA = Date(timeIntervalSince1970: 1_699_900_000)
        let occurrenceB = Date(timeIntervalSince1970: 1_699_990_000)

        let task = TaskItem(
            id: "abc",
            title: "Morning Routine",
            notes: "",
            linkedBlockId: "blk-1",
            status: .pending,
            priority: .high,
            tagIds: ["t1"],
            orderIndex: 2,
            estimatedMinutes: 15,
            createdAt: start,
            modifiedAt: start,
            body: .habit(rule: .daily, timeOfDay: timeOfDay, occurrences: [occurrenceA, occurrenceB]),
            reminders: [Reminder(trigger: .offset(.fiveMinutes))]
        )

        let data = try makeEncoder().encode(task)
        let decoded = try makeDecoder().decode(TaskItem.self, from: data)

        XCTAssertEqual(decoded, task)
        guard case .habit(let rule, let tod, let occs) = decoded.body else {
            return XCTFail("Expected .habit body")
        }
        XCTAssertEqual(rule, .daily)
        XCTAssertEqual(tod, timeOfDay)
        XCTAssertEqual(occs, [occurrenceA, occurrenceB])
        XCTAssertEqual(decoded.habitOccurrences, [occurrenceA, occurrenceB])
    }

    func testTaskRoundTripProducesEqualStruct() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let task = TaskItem(
            id: "round-trip",
            title: "Plan week",
            priority: .medium,
            createdAt: start,
            modifiedAt: start,
            body: .task(due: start, estimatedMinutes: nil)
        )

        let data = try makeEncoder().encode(task)
        let decoded = try makeDecoder().decode(TaskItem.self, from: data)

        XCTAssertEqual(decoded, task)
    }

    func testMilestoneRoundTrip() throws {
        let target = Date(timeIntervalSince1970: 1_710_000_000)
        let task = TaskItem(
            id: "m1",
            title: "Ship v2",
            body: .milestone(target: target)
        )

        let decoded = try makeDecoder().decode(TaskItem.self, from: makeEncoder().encode(task))
        XCTAssertEqual(decoded, task)
        guard case .milestone(let decodedTarget) = decoded.body else {
            return XCTFail("Expected .milestone body")
        }
        XCTAssertEqual(decodedTarget, target)
    }

    func testEventRoundTripPreservesEndTime() throws {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let end = start.addingTimeInterval(3600)
        let task = TaskItem(
            id: "e1",
            title: "Standup",
            body: .event(start: start, end: end)
        )

        let decoded = try makeDecoder().decode(TaskItem.self, from: makeEncoder().encode(task))
        XCTAssertEqual(decoded, task)
        XCTAssertEqual(decoded.endTime, end)
    }

    func testTaskDueByRoundTrip() throws {
        let due = Date(timeIntervalSince1970: 1_710_000_000)
        let task = TaskItem(
            id: "t1",
            title: "Buy milk",
            body: .task(due: due, estimatedMinutes: 25)
        )

        let decoded = try makeDecoder().decode(TaskItem.self, from: makeEncoder().encode(task))
        XCTAssertEqual(decoded, task)
        guard case .task(let decodedDue, let est) = decoded.body else {
            return XCTFail("Expected .task body")
        }
        XCTAssertEqual(decodedDue, due)
        XCTAssertEqual(est, 25)
    }

    func testMilestoneInitProducesMilestoneBody() {
        let target = Date(timeIntervalSince1970: 1_720_000_000)
        let task = TaskItem(id: "m2", title: "Launch", body: .milestone(target: target))
        XCTAssertEqual(task.kind, .milestone)
        XCTAssertEqual(task.anchorDate, target)
    }

    func testEventWithEndTimeInitProducesEventBody() {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let end = start.addingTimeInterval(1800)
        let task = TaskItem(id: "e2", title: "Sync", body: .event(start: start, end: end))
        XCTAssertEqual(task.kind, .event)
        XCTAssertEqual(task.endTime, end)
    }

    func testEncoderWritesBodyKey() throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let task = TaskItem(id: "dual", title: "body write", body: .task(due: start, estimatedMinutes: nil))

        let data = try makeEncoder().encode(task)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["body"], "body should be encoded")
        XCTAssertNotNil(json["reminders"], "reminders should be encoded")
        let body = try XCTUnwrap(json["body"] as? [String: Any])
        XCTAssertEqual(body["kind"] as? String, "task")
    }

    func testHabitCompletionHistoryRoundTripsThroughOccurrences() throws {
        let dates = [
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_700_086_400)
        ]
        let task = TaskItem(
            id: "h2",
            title: "Daily walk",
            body: .habit(rule: .daily, timeOfDay: Date(timeIntervalSince1970: 1_700_172_800), occurrences: dates)
        )

        XCTAssertEqual(task.habitOccurrences, dates)

        let decoded = try makeDecoder().decode(TaskItem.self, from: makeEncoder().encode(task))
        XCTAssertEqual(decoded.habitOccurrences, dates)
        XCTAssertEqual(decoded.habitCurrentStreak, task.habitCurrentStreak)
        XCTAssertEqual(decoded.habitLongestStreak, task.habitLongestStreak)
    }
}
