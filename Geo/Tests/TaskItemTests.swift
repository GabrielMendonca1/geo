import XCTest
@testable import Geo

final class TaskItemTests: XCTestCase {
    func testCustomRecurrenceClampsIntervalToMinimumOne() {
        let rule = RecurrenceRule.custom(every: 0, frequency: .weekly)

        XCTAssertEqual(rule.customInterval, 1)
        XCTAssertEqual(rule.customFrequency, .weekly)
    }

    func testCustomRecurrenceDisplayNameUsesSingularUnit() {
        let rule = RecurrenceRule.custom(every: 1, frequency: .daily)

        XCTAssertEqual(rule.displayName, "Every 1 Day")
    }

    func testCustomRecurrenceDisplayNameUsesPluralUnit() {
        let rule = RecurrenceRule.custom(every: 2, frequency: .monthly)

        XCTAssertEqual(rule.displayName, "Every 2 Months")
    }

    func testNeverRecurrenceIsNotRepeating() {
        XCTAssertFalse(RecurrenceRule.never.isRepeating)
    }

    func testWeeklyRecurrenceIsRepeating() {
        XCTAssertTrue(RecurrenceRule.weekly.isRepeating)
    }

    func testRecurringReminderApisQuarantined() throws {
        throw XCTSkip("Quarantined: RecurringReminder and TaskItem.nextReminderTime were part of the abandoned reminder model and no longer exist. Tasks now carry a flat [Reminder] with a per-reminder fired flag.")
    }

    func testIsDueTrueWhenReminderIsPastAndUnfired() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let item = makeTask(startTime: start, reminders: [.atTime])

        XCTAssertTrue(item.isDue(at: start.addingTimeInterval(1)))
    }

    func testIsDueFalseWhenReminderFired() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var item = makeTask(startTime: start, reminders: [.atTime])
        item.reminders = item.reminders.map { var r = $0; r.fired = true; return r }

        XCTAssertFalse(item.isDue(at: start.addingTimeInterval(1)))
    }

    func testCurrentDueReminderNilWhenCompleted() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let item = makeTask(startTime: start, status: .completed, reminders: [.atTime])

        XCTAssertNil(item.currentDueReminder(at: start.addingTimeInterval(1)))
    }

    func testRecurrenceRuleNextDateDaily() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let next = RecurrenceRule.daily.nextDate(after: start)
        let expected = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        XCTAssertEqual(next, expected)
    }

    func testRecurrenceRuleNextDateWeekly() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let next = RecurrenceRule.weekly.nextDate(after: start)
        let expected = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: start)!
        XCTAssertEqual(next, expected)
    }

    func testRecurrenceRuleNextDateBiweekly() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let next = RecurrenceRule.biweekly.nextDate(after: start)
        let expected = Calendar.current.date(byAdding: .weekOfYear, value: 2, to: start)!
        XCTAssertEqual(next, expected)
    }

    func testRecurrenceRuleNextDateMonthly() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let next = RecurrenceRule.monthly.nextDate(after: start)
        let expected = Calendar.current.date(byAdding: .month, value: 1, to: start)!
        XCTAssertEqual(next, expected)
    }

    func testRecurrenceRuleNextDateYearly() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let next = RecurrenceRule.yearly.nextDate(after: start)
        let expected = Calendar.current.date(byAdding: .year, value: 1, to: start)!
        XCTAssertEqual(next, expected)
    }

    func testRecurrenceRuleNextDateWeekdaysSkipsWeekend() {
        let calendar = Calendar.current
        var fridayComponents = DateComponents()
        fridayComponents.year = 2026
        fridayComponents.month = 3
        fridayComponents.day = 6
        fridayComponents.hour = 10
        let friday = calendar.date(from: fridayComponents)!
        XCTAssertEqual(calendar.component(.weekday, from: friday), 6)

        let next = RecurrenceRule.weekdays.nextDate(after: friday)!
        XCTAssertEqual(calendar.component(.weekday, from: next), 2)
    }

    func testRecurrenceRuleNextDateCustom() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let rule = RecurrenceRule.custom(every: 3, frequency: .monthly)
        let next = rule.nextDate(after: start)
        let expected = Calendar.current.date(byAdding: .month, value: 3, to: start)!
        XCTAssertEqual(next, expected)
    }

    func testRecurrenceRuleNextDateNeverReturnsNil() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let next = RecurrenceRule.never.nextDate(after: start)
        XCTAssertNil(next)
    }

    func testRecurrenceRuleNextDateDailyReturnsNextDay() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let next = RecurrenceRule.daily.nextDate(after: start)!
        let expected = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        XCTAssertEqual(next, expected)
    }

    func testRecurrenceRuleNextDateNeverFallback() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let next = RecurrenceRule.never.nextDate(after: start)
        XCTAssertNil(next)
    }

    func testNextDateReturnsNilPastEndDate() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let endDate = start.addingTimeInterval(3 * 86400)
        var rule = RecurrenceRule.daily
        rule.endDate = endDate
        let justBeforeEnd = endDate.addingTimeInterval(-1)
        XCTAssertNotNil(rule.nextDate(after: start))
        XCTAssertNil(rule.nextDate(after: endDate))
        let dayBeforeEnd = endDate.addingTimeInterval(-86400)
        let next = rule.nextDate(after: dayBeforeEnd)
        XCTAssertNotNil(next)
        XCTAssertNil(rule.nextDate(after: next!))
    }

    func testNextWeekdayAwareDateWithSpecificWeekdays() {
        let calendar = Calendar.current
        var mondayComponents = DateComponents()
        mondayComponents.year = 2026
        mondayComponents.month = 3
        mondayComponents.day = 9
        mondayComponents.hour = 10
        let monday = calendar.date(from: mondayComponents)!
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2)

        let rule = RecurrenceRule.weekly(on: [4, 6])
        let wed = rule.nextDate(after: monday)!
        XCTAssertEqual(calendar.component(.weekday, from: wed), 4)

        let fri = rule.nextDate(after: wed)!
        XCTAssertEqual(calendar.component(.weekday, from: fri), 6)

        let nextWed = rule.nextDate(after: fri)!
        XCTAssertEqual(calendar.component(.weekday, from: nextWed), 4)
    }

    func testRecurrenceRuleJsonRoundTripWithEndDateAndWeekdays() throws {
        let endDate = Date(timeIntervalSince1970: 1_710_000_000)
        let rule = RecurrenceRule(
            type: .weekly,
            endDate: endDate,
            selectedWeekdays: [2, 4, 6]
        )
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(RecurrenceRule.self, from: data)
        XCTAssertEqual(decoded.type, .weekly)
        XCTAssertEqual(decoded.endDate, endDate)
        XCTAssertEqual(decoded.selectedWeekdays, [2, 4, 6])
    }

    func testRecurrenceRuleJsonRoundTripWithoutOptionalFields() throws {
        let rule = RecurrenceRule.daily
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(RecurrenceRule.self, from: data)
        XCTAssertEqual(decoded.type, .daily)
        XCTAssertNil(decoded.endDate)
        XCTAssertNil(decoded.selectedWeekdays)
    }

    func testIsOverdueUsesEndTimeWhenPeriodTask() {
        let now = Date()
        let item = makeTask(startTime: now.addingTimeInterval(300), endTime: now.addingTimeInterval(-60), reminders: [.atTime])

        XCTAssertTrue(item.isOverdue)
    }

    func testIsOverdueFalseForRecurringTask() {
        let pastDate = Date().addingTimeInterval(-86400)
        let item = makeTask(startTime: pastDate, reminders: [.atTime], recurrence: .weekly)

        XCTAssertFalse(item.isOverdue)
    }

    func testIsOverdueFalseForDailyRecurringTask() {
        let pastDate = Date().addingTimeInterval(-3600)
        let item = makeTask(startTime: pastDate, reminders: [.atTime], recurrence: .daily)

        XCTAssertFalse(item.isOverdue)
    }

    func testIsOverdueTrueForNonRecurringPastTask() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let item = makeTask(startTime: yesterday, reminders: [.atTime])

        XCTAssertTrue(item.isOverdue)
    }

    func testIsOverdueFalseForTodayPointInTimeTask() {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let item = makeTask(startTime: oneHourAgo, reminders: [.atTime])

        XCTAssertFalse(item.isOverdue)
    }

    func testIsOverdueRespectsSnoozedUntil() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        var item = makeTask(startTime: yesterday, reminders: [.atTime])
        item.snoozedUntil = tomorrow

        XCTAssertFalse(item.isOverdue)
    }

    func testSmartReminderTriggersForRecurringTaskWithPastStartTime() {
        let pastDate = Date().addingTimeInterval(-86400)
        let task = makeTask(startTime: pastDate, reminders: [.atTime], recurrence: .weekly)

        XCTAssertFalse(task.isOverdue)
        XCTAssertTrue(task.recurrence.isRepeating)
        XCTAssertTrue(task.startTime < Date())
    }

    private func makeTask(
        startTime: Date,
        endTime: Date? = nil,
        status: TaskStatus = .pending,
        reminders: [ReminderOffset],
        firedReminders: [ReminderOffset] = [],
        snoozedUntil: Date? = nil,
        recurrence: RecurrenceRule = .never
    ) -> TaskItem {
        TaskItem(
            id: UUID().uuidString,
            title: "Task",
            notes: "",
            linkedBlockId: nil,
            status: status,
            startTime: startTime,
            endTime: endTime,
            reminders: reminders,
            recurringReminders: [],
            recurrence: recurrence,
            firedReminders: firedReminders,
            orderIndex: 0,
            smartReminder: false,
            snoozedUntil: snoozedUntil,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

final class RepositoryAdapterTests: XCTestCase {
    func testBlocksRepositoryAdapterCRUDAndNotFoundErrors() async throws {
        let access = InMemoryBlocksStoreAccess()
        let repository = BlocksStoreRepositoryAdapter(storeAccess: access)

        let created = try await repository.create(title: "My Block", markdown: "first")
        XCTAssertEqual(created.title, "My Block")

        try await repository.update(id: created.id, markdown: "updated")
        try await repository.setTag(blockId: created.id, tagId: "tag-1")

        let listed = try await repository.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].markdown, "updated")
        XCTAssertEqual(listed[0].tagId, "tag-1")

        try await repository.delete(id: created.id)
        let blocksAfterDelete = try await repository.list()
        XCTAssertTrue(blocksAfterDelete.isEmpty)

        await assertRepositoryError(.notFound) {
            try await repository.update(id: "missing.md", markdown: "x")
        }

        await assertRepositoryError(.notFound) {
            try await repository.delete(id: "missing.md")
        }
    }

    func testBlocksRepositoryAdapterObserveStreamsInitialSnapshotAndCRUDUpdates() async throws {
        let access = InMemoryBlocksStoreAccess()
        let repository = BlocksStoreRepositoryAdapter(storeAccess: access)
        var iterator = repository.observe().makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)

        let created = try await repository.create(title: "Observe Block", markdown: "initial")
        let afterCreate = await iterator.next()
        XCTAssertEqual(afterCreate?.map(\.id), [created.id])

        try await repository.update(id: created.id, markdown: "updated")
        let afterUpdate = await iterator.next()
        XCTAssertEqual(afterUpdate?.first?.markdown, "updated")

        try await repository.setTag(blockId: created.id, tagId: "tag-1")
        let afterSetTag = await iterator.next()
        XCTAssertEqual(afterSetTag?.first?.tagId, "tag-1")

        try await repository.delete(id: created.id)
        let afterDelete = await iterator.next()
        XCTAssertEqual(afterDelete?.count, 0)
    }

    func testBlocksRepositoryAdapterSearchReturnsMatchingBlocks() async throws {
        let access = InMemoryBlocksStoreAccess()
        let repository = BlocksStoreRepositoryAdapter(storeAccess: access)

        _ = try await repository.create(title: "Alpha", markdown: "notes about groceries")
        let beta = try await repository.create(title: "Beta", markdown: "contains phrase zebra fox")

        let results = try await repository.search(matching: "zebra")
        XCTAssertEqual(results.map(\.id), [beta.id])
    }

    func testTasksRepositoryAdapterCRUDAndErrorMapping() async throws {
        let access = InMemoryTasksStoreAccess()
        let repository = TasksStoreRepositoryAdapter(storeAccess: access)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = TaskDraft(
            title: "Review PR",
            notes: "adapter test",
            startTime: start,
            reminders: [.atTime]
        )

        let created = try await repository.create(draft)
        XCTAssertEqual(created.title, "Review PR")

        var edited = created
        edited.title = "Review PR (edited)"
        try await repository.update(edited)
        let listedTasks = try await repository.list()
        XCTAssertEqual(listedTasks.first?.title, "Review PR (edited)")

        try await repository.delete(id: edited.id)
        let tasksAfterDelete = try await repository.list()
        XCTAssertTrue(tasksAfterDelete.isEmpty)

        await assertRepositoryError(.invalidInput) {
            let emptyDraft = TaskDraft(title: "   ", startTime: start)
            _ = try await repository.create(emptyDraft)
        }

        await assertRepositoryError(.notFound) {
            try await repository.update(edited)
        }

        await assertRepositoryError(.notFound) {
            try await repository.delete(id: edited.id)
        }
    }

    func testTasksRepositoryAdapterObserveStreamsInitialSnapshotAndCRUDUpdates() async throws {
        let access = InMemoryTasksStoreAccess()
        let repository = TasksStoreRepositoryAdapter(storeAccess: access)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var iterator = repository.observe().makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)

        let created = try await repository.create(TaskDraft(title: "Observe me", startTime: start))
        let afterCreate = await iterator.next()
        XCTAssertEqual(afterCreate?.map(\.id), [created.id])

        var edited = created
        edited.status = .completed
        try await repository.update(edited)
        let afterUpdate = await iterator.next()
        XCTAssertEqual(afterUpdate?.first?.status, .completed)

        try await repository.delete(id: created.id)
        let afterDelete = await iterator.next()
        XCTAssertEqual(afterDelete?.count, 0)
    }

    func testCaptureRepositoryAdapterObserveAppendListDelete() async throws {
        let store = InMemoryCaptureStore()
        let repository = CaptureStoreRepositoryAdapter(storeAccess: store)
        var iterator = repository.observe().makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)

        let first = CaptureItem(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            timestamp: Date(timeIntervalSince1970: 1),
            fileName: "first",
            extractedText: nil,
            sourceURL: nil,
            previewData: nil,
            imageData: nil
        )
        let second = CaptureItem(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            timestamp: Date(timeIntervalSince1970: 2),
            fileName: "second",
            extractedText: nil,
            sourceURL: nil,
            previewData: nil,
            imageData: nil
        )

        try await repository.append(first)
        let afterFirstAppend = await iterator.next()
        XCTAssertEqual(afterFirstAppend?.map(\.id), [first.id])

        try await repository.append(second)
        let afterSecondAppend = await iterator.next()
        XCTAssertEqual(afterSecondAppend?.map(\.id), [second.id, first.id])

        let listed = try await repository.list()
        XCTAssertEqual(listed.map(\.id), [second.id, first.id])

        try await repository.delete(ids: [second.id])
        let afterDelete = await iterator.next()
        XCTAssertEqual(afterDelete?.map(\.id), [first.id])

        let capturesAfterDelete = try await repository.list()
        XCTAssertEqual(capturesAfterDelete.map(\.id), [first.id])
    }

    @MainActor func testSearchIndexingServiceAdapterRebuildIndexIndexAndRemove() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "geo-index-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempRoot)
        }

        let databaseURL = tempRoot.appendingPathComponent("index.sqlite")
        let database = DatabaseService(databaseURL: databaseURL, fileManager: fileManager)
        let indexCoordinator = IndexCoordinator(database: database, indexer: MarkdownIndexingService())

        let blockId = "test-block.md"
        let blockURL = tempRoot.appendingPathComponent(blockId)
        let now = Date()

        let block = BlocksStore.Block(
            id: blockId,
            title: "Index Me",
            date: now,
            lastEdited: now,
            markdown: "# Index Me\n#initial",
            url: blockURL,
            tagId: nil,
            metadata: .init()
        )

        await indexCoordinator.index(block: block)
        let indexedEntries = try await database.fetchBlocks(ids: [blockId])
        XCTAssertEqual(indexedEntries.count, 1)
        XCTAssertEqual(indexedEntries.first?.id, blockId)

        let edited = BlocksStore.Block(
            id: blockId,
            title: "Indexed Renamed Block",
            date: now,
            lastEdited: now.addingTimeInterval(1),
            markdown: "# Indexed Renamed Block\n#updated",
            url: blockURL,
            tagId: "tag-2",
            metadata: .init(dayId: nil, tagId: "tag-2")
        )
        await indexCoordinator.index(block: edited)

        let updatedEntries = try await database.fetchBlocks(ids: [blockId])
        XCTAssertEqual(updatedEntries.first?.title, "Indexed Renamed Block")
        XCTAssertEqual(updatedEntries.first?.tagId, "tag-2")

        await indexCoordinator.remove(blockId: blockId)
        let afterRemove = try await database.fetchBlocks(ids: [blockId])
        XCTAssertTrue(afterRemove.isEmpty)
    }

    private func assertRepositoryError(
        _ expected: RepositoryError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected error \(expected), but no error was thrown", file: file, line: line)
        } catch let error as RepositoryError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected RepositoryError \(expected), got \(error)", file: file, line: line)
        }
    }
}

@MainActor
final class TasksViewModelCompleteTests: XCTestCase {
    private var tasksRepository: TasksStoreRepositoryAdapter!
    private var viewModel: TasksViewModel!

    override func setUp() async throws {
        let tasksAccess = InMemoryTasksStoreAccess()
        tasksRepository = TasksStoreRepositoryAdapter(storeAccess: tasksAccess)
        let blocksAccess = InMemoryBlocksStoreAccess()
        let blocksRepository = BlocksStoreRepositoryAdapter(storeAccess: blocksAccess)
        viewModel = TasksViewModel()
        viewModel.bind(tasksRepository: tasksRepository, blocksRepository: blocksRepository)
    }

    func testCompleteRecurringTaskAdvancesToFuture() async throws {
        let yesterday = Date().addingTimeInterval(-86400)
        let created = try await tasksRepository.create(TaskDraft(
            title: "Weekly standup",
            startTime: yesterday,
            recurrence: .weekly
        ))
        try await waitForTasks(count: 1)

        await viewModel.completeTask(id: created.id)

        let tasks = try await tasksRepository.list()
        let task = tasks.first { $0.id == created.id }!
        XCTAssertTrue(task.startTime > Date())
        XCTAssertEqual(task.status, .pending)
        XCTAssertTrue(task.firedReminders.isEmpty)
        XCTAssertNil(task.snoozedUntil)
    }

    func testCompleteRecurringTaskSkipsPastOccurrences() async throws {
        let threeWeeksAgo = Date().addingTimeInterval(-3 * 7 * 86400)
        let created = try await tasksRepository.create(TaskDraft(
            title: "Weekly review",
            startTime: threeWeeksAgo,
            recurrence: .weekly
        ))
        try await waitForTasks(count: 1)

        await viewModel.completeTask(id: created.id)

        let tasks = try await tasksRepository.list()
        let task = tasks.first { $0.id == created.id }!
        XCTAssertTrue(task.startTime > Date())
    }

    func testCompleteRecurringTaskPreservesDuration() async throws {
        let yesterday10am = Calendar.current.date(
            bySettingHour: 10, minute: 0, second: 0,
            of: Date().addingTimeInterval(-86400)
        )!
        let yesterday11am = yesterday10am.addingTimeInterval(3600)
        let created = try await tasksRepository.create(TaskDraft(
            title: "Meeting",
            startTime: yesterday10am,
            endTime: yesterday11am,
            recurrence: .weekly
        ))
        try await waitForTasks(count: 1)

        await viewModel.completeTask(id: created.id)

        let tasks = try await tasksRepository.list()
        let task = tasks.first { $0.id == created.id }!
        XCTAssertNotNil(task.endTime)
        let duration = task.endTime!.timeIntervalSince(task.startTime)
        XCTAssertEqual(duration, 3600, accuracy: 1)
    }

    func testCompleteNonRecurringTaskMarksCompleted() async throws {
        let created = try await tasksRepository.create(TaskDraft(
            title: "One-off task",
            startTime: Date().addingTimeInterval(-3600),
            recurrence: .never
        ))
        try await waitForTasks(count: 1)

        await viewModel.completeTask(id: created.id)

        let tasks = try await tasksRepository.list()
        let task = tasks.first { $0.id == created.id }!
        XCTAssertEqual(task.status, .completed)
    }

    func testCompleteRecurringTaskKeepsRecurrenceRule() async throws {
        let yesterday = Date().addingTimeInterval(-86400)
        let created = try await tasksRepository.create(TaskDraft(
            title: "Biweekly sync",
            startTime: yesterday,
            recurrence: .biweekly
        ))
        try await waitForTasks(count: 1)

        await viewModel.completeTask(id: created.id)

        let tasks = try await tasksRepository.list()
        let task = tasks.first { $0.id == created.id }!
        XCTAssertEqual(task.recurrence, .biweekly)
    }

    func testCompleteRecurringTaskResetsRecurringRemindersLastFired() async throws {
        let yesterday = Date().addingTimeInterval(-86400)
        let reminder = RecurringReminder(
            interval: 1,
            frequency: .daily,
            timeOfDay: Date(),
            lastFired: yesterday
        )
        let created = try await tasksRepository.create(TaskDraft(
            title: "Daily with recurring reminder",
            startTime: yesterday,
            recurringReminders: [reminder],
            recurrence: .daily
        ))
        try await waitForTasks(count: 1)

        await viewModel.completeTask(id: created.id)

        let tasks = try await tasksRepository.list()
        let task = tasks.first { $0.id == created.id }!
        XCTAssertEqual(task.status, .pending)
        XCTAssertEqual(task.recurringReminders.count, 1)
        XCTAssertNil(task.recurringReminders[0].lastFired)
    }

    func testCompleteRecurringTaskPastEndDateMarksCompleted() async throws {
        let fourWeeksAgo = Date().addingTimeInterval(-4 * 7 * 86400)
        let twoWeeksAgo = Date().addingTimeInterval(-2 * 7 * 86400)
        var rule = RecurrenceRule.weekly
        rule.endDate = twoWeeksAgo
        let created = try await tasksRepository.create(TaskDraft(
            title: "Expired weekly",
            startTime: fourWeeksAgo,
            recurrence: rule
        ))
        try await waitForTasks(count: 1)

        await viewModel.completeTask(id: created.id)

        let tasks = try await tasksRepository.list()
        let task = tasks.first { $0.id == created.id }!
        XCTAssertEqual(task.status, .completed)
    }

    func testCompleteRecurringTaskExhaustedByEndDateMarksCompleted() async throws {
        let threeWeeksAgo = Date().addingTimeInterval(-3 * 7 * 86400)
        let sixDaysAgo = Date().addingTimeInterval(-6 * 86400)
        var rule = RecurrenceRule.weekly
        rule.endDate = sixDaysAgo
        let created = try await tasksRepository.create(TaskDraft(
            title: "Exhausted weekly",
            startTime: threeWeeksAgo,
            recurrence: rule
        ))
        try await waitForTasks(count: 1)

        await viewModel.completeTask(id: created.id)

        let tasks = try await tasksRepository.list()
        let task = tasks.first { $0.id == created.id }!
        XCTAssertEqual(task.status, .completed)
    }

    private func waitForTasks(count: Int) async throws {
        let deadline = Date().addingTimeInterval(2)
        while viewModel.tasks.count < count {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(count) tasks, got \(viewModel.tasks.count)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class InMemoryBlocksStoreAccess: BlocksStoreAccess, @unchecked Sendable {
    private var blocks: [BlocksStore.Block] = []
    private var continuations: [UUID: AsyncStream<[BlocksStore.Block]>.Continuation] = [:]

    func observeBlocks() -> AsyncStream<[BlocksStore.Block]> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(blocks)
            continuation.onTermination = { [weak self] _ in
                self?.continuations.removeValue(forKey: id)
            }
        }
    }

    func allBlocks() async -> [BlocksStore.Block] {
        blocks
    }

    func searchBlocks(matching query: String) async -> [BlocksStore.Block] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return blocks.filter { block in
            block.title.localizedCaseInsensitiveContains(trimmed)
                || block.markdown.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func createBlock(title: String, markdown: String) async -> BlocksStore.Block? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let id = UUID().uuidString + ".md"
        let block = BlocksStore.Block(
            id: id,
            title: trimmedTitle,
            date: now,
            lastEdited: now,
            markdown: markdown,
            url: URL(fileURLWithPath: "/tmp/\(id)"),
            tagId: nil,
            metadata: .init()
        )
        blocks.insert(block, at: 0)
        publishSnapshot()
        return block
    }

    func updateBlock(id: String, markdown: String) async -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let existing = blocks[index]
        blocks[index] = BlocksStore.Block(
            id: existing.id,
            title: existing.title,
            date: existing.date,
            lastEdited: Date(),
            markdown: markdown,
            url: existing.url,
            tagId: existing.tagId,
            metadata: existing.metadata
        )
        publishSnapshot()
        return true
    }

    func deleteBlock(id: String) async -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        blocks.remove(at: index)
        publishSnapshot()
        return true
    }

    func setTag(_ tagId: String?, for blockId: String) async -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == blockId }) else {
            return false
        }
        let existing = blocks[index]
        var metadata = existing.metadata
        metadata.tagId = tagId
        blocks[index] = BlocksStore.Block(
            id: existing.id,
            title: existing.title,
            date: existing.date,
            lastEdited: existing.lastEdited,
            markdown: existing.markdown,
            url: existing.url,
            tagId: tagId,
            metadata: metadata
        )
        publishSnapshot()
        return true
    }

    func checkboxes(in blockId: String) async -> [BlockCheckbox] {
        guard let block = blocks.first(where: { $0.id == blockId }) else { return [] }
        var results: [BlockCheckbox] = []
        for (index, line) in block.markdown.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [ ] ") {
                results.append(BlockCheckbox(text: String(trimmed.dropFirst(6)), checked: false, lineNumber: index + 1))
            } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                results.append(BlockCheckbox(text: String(trimmed.dropFirst(6)), checked: true, lineNumber: index + 1))
            }
        }
        return results
    }

    func toggleCheckbox(in blockId: String, lineNumber: Int) async throws {
        guard let index = blocks.firstIndex(where: { $0.id == blockId }) else { return }
        var lines = blocks[index].markdown.components(separatedBy: "\n")
        guard lineNumber >= 1, lineNumber <= lines.count else { return }
        let raw = lines[lineNumber - 1]
        if let r = raw.range(of: "[ ]") {
            lines[lineNumber - 1] = raw.replacingCharacters(in: r, with: "[x]")
        } else if let r = raw.range(of: "[x]") ?? raw.range(of: "[X]") {
            lines[lineNumber - 1] = raw.replacingCharacters(in: r, with: "[ ]")
        }
        _ = await updateBlock(id: blockId, markdown: lines.joined(separator: "\n"))
    }

    func setFullWidth(_ isFullWidth: Bool, for blockId: String) async -> Bool { false }
    func setLayer(_ layer: BlockLayer, for blockId: String) async -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == blockId }) else {
            return false
        }
        let existing = blocks[index]
        var metadata = existing.metadata
        metadata.layer = layer
        blocks[index] = BlocksStore.Block(
            id: existing.id,
            title: existing.title,
            date: existing.date,
            lastEdited: existing.lastEdited,
            markdown: existing.markdown,
            url: existing.url,
            tagId: existing.tagId,
            metadata: metadata
        )
        publishSnapshot()
        return true
    }
    func setType(_ type: BlockType, for blockId: String) async -> Bool { false }
    func setStatus(_ status: String?, for blockId: String) async -> Bool { false }

    func mutateFrontmatter(blockId: String, merge: [String: AnyCodableValue]) async throws -> Int {
        guard let index = blocks.firstIndex(where: { $0.id == blockId }) else {
            throw FrontmatterMutationError.blockNotFound(blockId)
        }
        let existing = blocks[index]
        let newVersion = existing.metadata.frontmatter_version + 1
        var mergeWithVersion = merge
        mergeWithVersion["frontmatter_version"] = .int(newVersion)
        let newMarkdown = FrontmatterEditor.upsert(in: existing.markdown, values: mergeWithVersion)
        var metadata = existing.metadata
        metadata.frontmatter_version = newVersion
        blocks[index] = BlocksStore.Block(
            id: existing.id,
            title: existing.title,
            date: existing.date,
            lastEdited: Date(),
            markdown: newMarkdown,
            url: existing.url,
            tagId: existing.tagId,
            metadata: metadata
        )
        publishSnapshot()
        return newVersion
    }

    @MainActor
    func updateBlockAndFlush(id: String, markdown: String) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let existing = blocks[index]
        blocks[index] = BlocksStore.Block(
            id: existing.id,
            title: existing.title,
            date: existing.date,
            lastEdited: Date(),
            markdown: markdown,
            url: existing.url,
            tagId: existing.tagId,
            metadata: existing.metadata
        )
        publishSnapshot()
        return true
    }

    private func publishSnapshot() {
        for continuation in continuations.values {
            continuation.yield(blocks)
        }
    }
}

private final class InMemoryTasksStoreAccess: TasksStoreAccess, @unchecked Sendable {
    private var tasks: [TaskItem] = []
    private var continuations: [UUID: AsyncStream<[TaskItem]>.Continuation] = [:]

    func observeTasks() -> AsyncStream<[TaskItem]> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(tasks)
            continuation.onTermination = { [weak self] _ in
                self?.continuations.removeValue(forKey: id)
            }
        }
    }

    func allTasks() async -> [TaskItem] {
        tasks
    }

    func importTask(_ task: TaskItem) async -> Bool {
        guard tasks.contains(where: { $0.id == task.id }) == false else {
            return false
        }
        tasks.append(task)
        publishSnapshot()
        return true
    }

    func createTask(from draft: TaskDraft) async -> TaskItem? {
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return nil
        }

        let task = TaskItem(
            id: UUID().uuidString,
            title: trimmedTitle,
            notes: draft.notes,
            linkedBlockId: draft.linkedBlockId,
            status: .pending,
            startTime: draft.startTime,
            endTime: draft.endTime,
            reminders: draft.reminders,
            recurringReminders: draft.recurringReminders,
            recurrence: draft.recurrence,
            firedReminders: [],
            orderIndex: tasks.count,
            smartReminder: draft.smartReminder,
            snoozedUntil: nil,
            createdAt: Date(),
            modifiedAt: Date()
        )
        tasks.append(task)
        publishSnapshot()
        return task
    }

    func updateTask(_ task: TaskItem) async -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            return false
        }
        tasks[index] = task
        publishSnapshot()
        return true
    }

    func deleteTask(id: String) async -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        tasks.remove(at: index)
        publishSnapshot()
        return true
    }

    private func publishSnapshot() {
        for continuation in continuations.values {
            continuation.yield(tasks)
        }
    }
}

private final class InMemoryCaptureStore: CaptureStoreAccess, @unchecked Sendable {
    private var captures: [CaptureItem] = []
    private var captureDayLinks: [UUID: String] = [:]
    private var continuations: [UUID: AsyncStream<[CaptureItem]>.Continuation] = [:]

    func observeCaptures() -> AsyncStream<[CaptureItem]> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(captures)
            continuation.onTermination = { [weak self] _ in
                self?.continuations.removeValue(forKey: id)
            }
        }
    }

    func allCaptures() async -> [CaptureItem] {
        captures
    }

    func appendCapture(_ item: CaptureItem) async -> Bool {
        if captures.contains(where: { $0.id == item.id }) {
            return false
        }
        captures.insert(item, at: 0)
        if let dayId = item.dayId {
            captureDayLinks[item.id] = dayId
        }
        publishSnapshot()
        return true
    }

    func linkCaptureToDay(_ captureId: UUID, dayId: String) async -> Bool {
        guard let index = captures.firstIndex(where: { $0.id == captureId }) else {
            return false
        }

        captureDayLinks[captureId] = dayId
        captures[index].dayId = dayId
        publishSnapshot()
        return true
    }

    func deleteCaptures(with ids: Set<UUID>) async -> Int {
        let previousCount = captures.count
        captures.removeAll { ids.contains($0.id) }
        for id in ids {
            captureDayLinks.removeValue(forKey: id)
        }
        publishSnapshot()
        return previousCount - captures.count
    }

    private func publishSnapshot() {
        for continuation in continuations.values {
            continuation.yield(captures)
        }
    }
}
