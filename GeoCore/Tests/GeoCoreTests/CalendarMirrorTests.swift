import Foundation
import XCTest
@testable import GeoCore

final class CalendarMirrorTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func testMarkerRoundTrips() {
        let marker = CalendarMirror.marker(for: "task-42")
        XCTAssertEqual(marker, "[Garime:task-42]")
        XCTAssertEqual(CalendarMirror.taskId(inNotes: marker), "task-42")
        XCTAssertEqual(CalendarMirror.taskId(inNotes: "nota do usuário\n\n" + marker), "task-42")
        XCTAssertNil(CalendarMirror.taskId(inNotes: "reunião com o time"))
        XCTAssertNil(CalendarMirror.taskId(inNotes: nil))
        XCTAssertNil(CalendarMirror.taskId(inNotes: "[Garime:]"))
        XCTAssertNil(CalendarMirror.taskId(inNotes: "[Garime:sem fechamento"))
    }

    func testOnlyPendingEventsProduceEntries() {
        let start = date(2025, 3, 10, 9, 0)
        XCTAssertNotNil(CalendarMirror.entry(for: event(id: "e1", start: start)))
        XCTAssertNil(CalendarMirror.entry(for: event(id: "e2", start: start, status: .completed)))
        XCTAssertNil(CalendarMirror.entry(for: task(id: "t1", due: start)))
        XCTAssertNil(CalendarMirror.entry(for: milestone(id: "m1", target: start)))
        XCTAssertNil(CalendarMirror.entry(for: habit(id: "h1", timeOfDay: start)))
    }

    func testEntryClampsInvertedIntervalAndFallsBackOnEmptyTitle() {
        let start = date(2025, 3, 10, 9, 0)
        let broken = event(id: "e1", title: "   ", start: start, end: date(2025, 3, 10, 8, 0))
        let entry = CalendarMirror.entry(for: broken)
        XCTAssertEqual(entry?.end, start)
        XCTAssertEqual(entry?.title, CalendarMirror.untitledFallback)
        XCTAssertEqual(entry?.notes, "[Garime:e1]")
    }

    func testPlanCreatesMissingEvents() {
        let start = date(2025, 3, 10, 9, 0)
        let actions = plan(tasks: [event(id: "e1", title: "Dentista", start: start)], existing: [])
        guard case .create(let entry)? = actions.first, actions.count == 1 else {
            return XCTFail("expected a single create, got \(actions)")
        }
        XCTAssertEqual(entry.taskId, "e1")
        XCTAssertEqual(entry.title, "Dentista")
        XCTAssertEqual(entry.start, start)
    }

    func testPlanIsIdempotentWhenMirrorMatches() {
        let start = date(2025, 3, 10, 9, 0)
        let task = event(id: "e1", title: "Dentista", start: start)
        let existing = mirrored(eventId: "ek-1", taskId: "e1", title: "Dentista", start: start, end: start.addingTimeInterval(3600))
        XCTAssertTrue(plan(tasks: [task], existing: [existing]).isEmpty)
    }

    func testSubSecondDriftDoesNotTriggerUpdate() {
        let start = date(2025, 3, 10, 9, 0)
        let task = event(id: "e1", title: "Dentista", start: start)
        let existing = mirrored(
            eventId: "ek-1",
            taskId: "e1",
            title: "Dentista",
            start: start.addingTimeInterval(0.4),
            end: start.addingTimeInterval(3600.3)
        )
        XCTAssertTrue(plan(tasks: [task], existing: [existing]).isEmpty)
    }

    func testAllDayComparesByDayNotByInstant() {
        let start = date(2025, 3, 10, 0, 0)
        let task = event(id: "e1", title: "Feriado", start: start, end: start, isAllDay: true)
        let existing = mirrored(
            eventId: "ek-1",
            taskId: "e1",
            title: "Feriado",
            start: date(2025, 3, 10, 11, 30),
            end: date(2025, 3, 10, 23, 0),
            isAllDay: true
        )
        XCTAssertTrue(plan(tasks: [task], existing: [existing]).isEmpty)
    }

    func testPlanUpdatesChangedFields() {
        let start = date(2025, 3, 10, 9, 0)
        let task = event(id: "e1", title: "Dentista novo", start: start)
        let existing = mirrored(eventId: "ek-1", taskId: "e1", title: "Dentista", start: start, end: start.addingTimeInterval(3600))
        let actions = plan(tasks: [task], existing: [existing])
        guard case .update(let eventId, let entry)? = actions.first, actions.count == 1 else {
            return XCTFail("expected a single update, got \(actions)")
        }
        XCTAssertEqual(eventId, "ek-1")
        XCTAssertEqual(entry.title, "Dentista novo")
    }

    func testPlanDeletesCompletedDeletedAndNoLongerEventTasks() {
        let start = date(2025, 3, 10, 9, 0)
        let existing = [
            mirrored(eventId: "ek-completed", taskId: "completed", title: "A", start: start, end: start),
            mirrored(eventId: "ek-gone", taskId: "gone", title: "B", start: start, end: start),
            mirrored(eventId: "ek-demoted", taskId: "demoted", title: "C", start: start, end: start)
        ]
        let tasks = [
            event(id: "completed", title: "A", start: start, status: .completed),
            task(id: "demoted", title: "C", due: start)
        ]
        XCTAssertEqual(
            plan(tasks: tasks, existing: existing),
            [.delete(eventId: "ek-completed"), .delete(eventId: "ek-demoted"), .delete(eventId: "ek-gone")]
        )
    }

    func testPlanCollapsesDuplicateMirrorsForSameTask() {
        let start = date(2025, 3, 10, 9, 0)
        let task = event(id: "e1", title: "Dentista", start: start)
        let existing = [
            mirrored(eventId: "ek-2", taskId: "e1", title: "Dentista", start: start, end: start.addingTimeInterval(3600)),
            mirrored(eventId: "ek-1", taskId: "e1", title: "Dentista", start: start, end: start.addingTimeInterval(3600))
        ]
        XCTAssertEqual(plan(tasks: [task], existing: existing), [.delete(eventId: "ek-2")])
    }

    func testPlanIgnoresTasksOutsideWindowAndKeepsOverlapping() {
        let window = DateInterval(start: date(2025, 3, 1, 0, 0), end: date(2025, 4, 1, 0, 0))
        let far = event(id: "far", title: "Longe", start: date(2026, 1, 1, 9, 0))
        let overlapping = event(
            id: "overlap",
            title: "Atravessa",
            start: date(2025, 2, 26, 9, 0),
            end: date(2025, 3, 2, 9, 0)
        )
        let actions = plan(tasks: [far, overlapping], existing: [], window: window)
        XCTAssertEqual(actions.count, 1)
        guard case .create(let entry)? = actions.first else {
            return XCTFail("expected a create, got \(actions)")
        }
        XCTAssertEqual(entry.taskId, "overlap")
    }

    func testPlanIgnoresDuplicateTaskIdsInInput() {
        let start = date(2025, 3, 10, 9, 0)
        let tasks = [event(id: "e1", title: "Primeiro", start: start), event(id: "e1", title: "Segundo", start: start)]
        let actions = plan(tasks: tasks, existing: [])
        XCTAssertEqual(actions.count, 1)
        guard case .create(let entry)? = actions.first else {
            return XCTFail("expected a create, got \(actions)")
        }
        XCTAssertEqual(entry.title, "Primeiro")
    }

    private func plan(
        tasks: [TaskItem],
        existing: [CalendarMirrorEvent],
        window: DateInterval? = nil
    ) -> [CalendarMirrorAction] {
        CalendarMirror.plan(tasks: tasks, existing: existing, in: window, calendar: calendar)
    }

    private func mirrored(
        eventId: String,
        taskId: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false
    ) -> CalendarMirrorEvent {
        CalendarMirrorEvent(eventId: eventId, taskId: taskId, title: title, start: start, end: end, isAllDay: isAllDay)
    }

    private func event(
        id: String,
        title: String = "Evento",
        start: Date,
        end: Date? = nil,
        status: TaskStatus = .pending,
        isAllDay: Bool? = nil
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            status: status,
            body: .event(start: start, end: end ?? start.addingTimeInterval(3600), externalEKEventID: nil),
            isAllDay: isAllDay ?? false
        )
    }

    private func task(id: String, title: String = "Tarefa", due: Date) -> TaskItem {
        TaskItem(id: id, title: title, body: .task(due: due, estimatedMinutes: nil))
    }

    private func milestone(id: String, target: Date) -> TaskItem {
        TaskItem(id: id, title: "Marco", body: .milestone(target: target))
    }

    private func habit(id: String, timeOfDay: Date) -> TaskItem {
        TaskItem(id: id, title: "Hábito", body: .habit(rule: .daily, timeOfDay: timeOfDay, occurrences: []))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
