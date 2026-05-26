import XCTest
@testable import Geo

@MainActor
final class HabitCompletionTests: XCTestCase {

    func testCompleteHabitOnNonHabitTaskThrows() async {
        let task = makeTask(kind: .task)
        let persister = StubPersister(initial: [task])
        let blocks = StubBlocks()

        do {
            try await TasksStore.completeHabitOccurrence(
                taskId: task.id,
                blocksStore: blocks,
                at: Date(),
                persister: persister
            )
            XCTFail("Expected notAHabit error")
        } catch let error as HabitCompletionError {
            XCTAssertEqual(error, .notAHabit)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRecordsOccurrenceWithCorrectDate() async throws {
        let task = makeHabit()
        let persister = StubPersister(initial: [task])
        let blocks = StubBlocks()
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        try await TasksStore.completeHabitOccurrence(
            taskId: task.id,
            blocksStore: blocks,
            at: when,
            persister: persister
        )

        let updated = persister.task(for: task.id)!
        XCTAssertEqual(updated.habitState?.occurrences.count, 1)
        XCTAssertEqual(updated.habitState?.occurrences.first?.date, when)
    }

    func testCurrentStreakIncrementsOnConsecutiveDayResetsOnGap() async throws {
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let day1 = calendar.date(byAdding: .day, value: 1, to: day0)!
        let day3 = calendar.date(byAdding: .day, value: 3, to: day0)!

        let task = makeHabit()
        let persister = StubPersister(initial: [task])
        let blocks = StubBlocks()

        try await TasksStore.completeHabitOccurrence(
            taskId: task.id, blocksStore: blocks, at: day0, persister: persister
        )
        XCTAssertEqual(persister.task(for: task.id)?.habitState?.currentStreak, 1)

        try await TasksStore.completeHabitOccurrence(
            taskId: task.id, blocksStore: blocks, at: day1, persister: persister
        )
        XCTAssertEqual(persister.task(for: task.id)?.habitState?.currentStreak, 2)

        try await TasksStore.completeHabitOccurrence(
            taskId: task.id, blocksStore: blocks, at: day3, persister: persister
        )
        XCTAssertEqual(persister.task(for: task.id)?.habitState?.currentStreak, 1)
    }

    func testLongestStreakNeverDecreases() async throws {
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let day1 = calendar.date(byAdding: .day, value: 1, to: day0)!
        let day2 = calendar.date(byAdding: .day, value: 2, to: day0)!
        let day10 = calendar.date(byAdding: .day, value: 10, to: day0)!

        let task = makeHabit()
        let persister = StubPersister(initial: [task])
        let blocks = StubBlocks()

        try await TasksStore.completeHabitOccurrence(taskId: task.id, blocksStore: blocks, at: day0, persister: persister)
        try await TasksStore.completeHabitOccurrence(taskId: task.id, blocksStore: blocks, at: day1, persister: persister)
        try await TasksStore.completeHabitOccurrence(taskId: task.id, blocksStore: blocks, at: day2, persister: persister)
        let longestAfter3 = persister.task(for: task.id)?.habitState?.longestStreak
        XCTAssertEqual(longestAfter3, 3)

        try await TasksStore.completeHabitOccurrence(taskId: task.id, blocksStore: blocks, at: day10, persister: persister)
        let updated = persister.task(for: task.id)!
        XCTAssertEqual(updated.habitState?.currentStreak, 1)
        XCTAssertEqual(updated.habitState?.longestStreak, 3)
    }

    func testResetCheckboxesCalledWhenEnabledAndBlockLinked() async throws {
        let blocks = StubBlocks()
        blocks.set(blockId: "block-a", checkboxes: [
            BlockCheckbox(text: "stretch", checked: true, lineNumber: 1),
            BlockCheckbox(text: "read", checked: false, lineNumber: 2)
        ])
        var task = makeHabit(blockId: "block-a")
        task.habitState?.resetCheckboxesOnComplete = true
        let persister = StubPersister(initial: [task])

        try await TasksStore.completeHabitOccurrence(
            taskId: task.id, blocksStore: blocks, at: Date(), persister: persister
        )

        XCTAssertEqual(blocks.resetCalls, ["block-a"])
    }

    func testResetCheckboxesNotCalledWhenDisabled() async throws {
        let blocks = StubBlocks()
        blocks.set(blockId: "block-a", checkboxes: [
            BlockCheckbox(text: "stretch", checked: true, lineNumber: 1)
        ])
        var task = makeHabit(blockId: "block-a")
        task.habitState?.resetCheckboxesOnComplete = false
        let persister = StubPersister(initial: [task])

        try await TasksStore.completeHabitOccurrence(
            taskId: task.id, blocksStore: blocks, at: Date(), persister: persister
        )

        XCTAssertTrue(blocks.resetCalls.isEmpty)
    }

    func testDailyRecurringScheduleAdvancesByOneDayAndStaysPending() async throws {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_700_000_000))!
        var task = makeHabit()
        task.startTime = start
        task.recurrence = .daily
        task.schedule = .recurring(rule: .daily, timeOfDay: start)
        let persister = StubPersister(initial: [task])
        let blocks = StubBlocks()

        try await TasksStore.completeHabitOccurrence(
            taskId: task.id, blocksStore: blocks, at: start, persister: persister
        )

        let updated = persister.task(for: task.id)!
        XCTAssertEqual(updated.status, .pending)
        let expected = calendar.date(byAdding: .day, value: 1, to: start)!
        XCTAssertEqual(updated.startTime, expected)
    }

    func testRecurrenceEndedMarksTaskCompleted() async throws {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_700_000_000))!
        let endDate = calendar.date(byAdding: .hour, value: 1, to: start)!
        var rule = RecurrenceRule.daily
        rule.endDate = endDate
        var task = makeHabit()
        task.startTime = start
        task.recurrence = rule
        task.schedule = .recurring(rule: rule, timeOfDay: start)
        let persister = StubPersister(initial: [task])
        let blocks = StubBlocks()

        try await TasksStore.completeHabitOccurrence(
            taskId: task.id, blocksStore: blocks, at: start, persister: persister
        )

        let updated = persister.task(for: task.id)!
        XCTAssertEqual(updated.status, .completed)
    }

    func testSnapshotCapturesBlockCheckboxesIntoOccurrence() async throws {
        let blocks = StubBlocks()
        blocks.set(blockId: "block-b", checkboxes: [
            BlockCheckbox(text: "alpha", checked: true, lineNumber: 1),
            BlockCheckbox(text: "beta", checked: false, lineNumber: 2),
            BlockCheckbox(text: "gamma", checked: true, lineNumber: 3)
        ])
        let task = makeHabit(blockId: "block-b")
        let persister = StubPersister(initial: [task])

        try await TasksStore.completeHabitOccurrence(
            taskId: task.id, blocksStore: blocks, at: Date(), persister: persister
        )

        let updated = persister.task(for: task.id)!
        let snapshot = updated.habitState?.occurrences.last?.checkboxes ?? []
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(snapshot[0], CheckboxSnapshot(text: "alpha", wasChecked: true))
        XCTAssertEqual(snapshot[1], CheckboxSnapshot(text: "beta", wasChecked: false))
        XCTAssertEqual(snapshot[2], CheckboxSnapshot(text: "gamma", wasChecked: true))
    }

    private func makeHabit(blockId: String? = nil) -> TaskItem {
        let timeOfDay = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_700_000_000))!
        return TaskItem(
            id: UUID().uuidString,
            title: "Habit",
            notes: "",
            linkedBlockId: blockId,
            status: .pending,
            startTime: timeOfDay,
            endTime: nil,
            reminders: [],
            recurringReminders: [],
            recurrence: .daily,
            firedReminders: [],
            orderIndex: 0,
            smartReminder: false,
            snoozedUntil: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0),
            kind: .habit,
            schedule: .recurring(rule: .daily, timeOfDay: timeOfDay),
            habitState: HabitState(resetCheckboxesOnComplete: true)
        )
    }

    private func makeTask(kind: TaskKind) -> TaskItem {
        TaskItem(
            id: UUID().uuidString,
            title: "Task",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            kind: kind
        )
    }
}

@MainActor
private final class StubPersister: HabitTaskPersisting {
    private var storage: [String: TaskItem] = [:]

    init(initial: [TaskItem]) {
        for item in initial { storage[item.id] = item }
    }

    func task(for id: String) -> TaskItem? {
        storage[id]
    }

    func replaceTask(_ task: TaskItem) {
        storage[task.id] = task
    }
}

@MainActor
private final class StubBlocks: HabitCheckboxProvider {
    private var byBlock: [String: [BlockCheckbox]] = [:]
    private(set) var resetCalls: [String] = []

    func set(blockId: String, checkboxes: [BlockCheckbox]) {
        byBlock[blockId] = checkboxes
    }

    func checkboxes(in blockId: String) -> [BlockCheckbox] {
        byBlock[blockId] ?? []
    }

    @discardableResult
    func resetCheckedCheckboxes(in blockId: String) async throws -> [BlockCheckboxSnapshot] {
        resetCalls.append(blockId)
        let snapshots = (byBlock[blockId] ?? []).map {
            BlockCheckboxSnapshot(text: $0.text, wasChecked: $0.checked)
        }
        byBlock[blockId] = (byBlock[blockId] ?? []).map {
            BlockCheckbox(text: $0.text, checked: false, lineNumber: $0.lineNumber)
        }
        return snapshots
    }
}
