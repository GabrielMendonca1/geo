import XCTest
@testable import Geo

final class QuickAddParserTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    private func makeNow(year: Int = 2025, month: Int = 4, day: Int = 16, hour: Int = 9, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        c.minute = minute
        return calendar.date(from: c)!
    }

    private func components(_ date: Date, _ fields: Set<Calendar.Component>) -> DateComponents {
        calendar.dateComponents(fields, from: date)
    }

    func testEmptyInputIsLowConfidenceTask() {
        let result = QuickAddParser.parse("", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.kind, .task)
        XCTAssertEqual(result.schedule, .anytime)
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.title, "")
    }

    func testPlainTaskFallsBackToAnytime() {
        let result = QuickAddParser.parse("Buy milk", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.kind, .task)
        XCTAssertEqual(result.schedule, .anytime)
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.title, "Buy milk")
    }

    func testWhitespaceTrimmed() {
        let result = QuickAddParser.parse("   Read book   ", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.title, "Read book")
        XCTAssertEqual(result.kind, .task)
    }

    func testReadFor30MinIsAnytime() {
        let result = QuickAddParser.parse("Read for 30 min", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.kind, .task)
        XCTAssertEqual(result.schedule, .anytime)
        XCTAssertEqual(result.title, "Read")
    }

    func testStandupAt10amCreatesEventToday() {
        let now = makeNow(hour: 8)
        let result = QuickAddParser.parse("Standup at 10am", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .event)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.title, "Standup")
        guard case .at(let date, let duration) = result.schedule else {
            return XCTFail("Expected .at schedule")
        }
        XCTAssertEqual(duration, 3600)
        let comps = components(date, [.year, .month, .day, .hour, .minute])
        XCTAssertEqual(comps.year, 2025)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 16)
        XCTAssertEqual(comps.hour, 10)
        XCTAssertEqual(comps.minute, 0)
    }

    func testTimeInPastBumpsToTomorrow() {
        let now = makeNow(hour: 14)
        let result = QuickAddParser.parse("Coffee at 10am", now: now, calendar: calendar)
        guard case .at(let date, _) = result.schedule else {
            return XCTFail("Expected .at schedule")
        }
        let comps = components(date, [.day, .hour])
        XCTAssertEqual(comps.day, 17)
        XCTAssertEqual(comps.hour, 10)
    }

    func testEventAt3pm() {
        let result = QuickAddParser.parse("Call dentist at 3pm", now: makeNow(hour: 8), calendar: calendar)
        XCTAssertEqual(result.kind, .event)
        guard case .at(let date, _) = result.schedule else { return XCTFail() }
        XCTAssertEqual(components(date, [.hour, .minute]).hour, 15)
    }

    func testEventWithMinutes10_30am() {
        let result = QuickAddParser.parse("Sync 10:30am", now: makeNow(hour: 8), calendar: calendar)
        XCTAssertEqual(result.kind, .event)
        guard case .at(let date, _) = result.schedule else { return XCTFail() }
        let c = components(date, [.hour, .minute])
        XCTAssertEqual(c.hour, 10)
        XCTAssertEqual(c.minute, 30)
        XCTAssertEqual(result.title, "Sync")
    }

    func test24HourTime() {
        let result = QuickAddParser.parse("Standup at 14:30", now: makeNow(hour: 8), calendar: calendar)
        XCTAssertEqual(result.kind, .event)
        guard case .at(let date, _) = result.schedule else { return XCTFail() }
        let c = components(date, [.hour, .minute])
        XCTAssertEqual(c.hour, 14)
        XCTAssertEqual(c.minute, 30)
    }

    func testEventWithDuration1h() {
        let result = QuickAddParser.parse("Workshop at 2pm for 1 hour", now: makeNow(hour: 8), calendar: calendar)
        XCTAssertEqual(result.kind, .event)
        guard case .at(_, let duration) = result.schedule else { return XCTFail() }
        XCTAssertEqual(duration, 3600)
        XCTAssertEqual(result.title, "Workshop")
    }

    func testEventDuration30Min() {
        let result = QuickAddParser.parse("Quick call at 4pm for 30 min", now: makeNow(hour: 8), calendar: calendar)
        guard case .at(_, let duration) = result.schedule else { return XCTFail() }
        XCTAssertEqual(duration, 30 * 60)
    }

    func test12pmIsNoon() {
        let result = QuickAddParser.parse("Lunch at 12pm", now: makeNow(hour: 8), calendar: calendar)
        guard case .at(let date, _) = result.schedule else { return XCTFail() }
        XCTAssertEqual(components(date, [.hour]).hour, 12)
    }

    func test12amIsMidnight() {
        let result = QuickAddParser.parse("Cron at 12am", now: makeNow(hour: 8), calendar: calendar)
        guard case .at(let date, _) = result.schedule else { return XCTFail() }
        XCTAssertEqual(components(date, [.hour]).hour, 0)
    }

    func testStretchEveryMorningIsHabitAt7am() {
        let result = QuickAddParser.parse("Stretch every morning", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.kind, .habit)
        guard case .recurring(let rule, let timeOfDay) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .daily)
        XCTAssertEqual(components(timeOfDay, [.hour]).hour, 7)
        XCTAssertEqual(result.title, "Stretch")
    }

    func testEveryEveningIs6pm() {
        let result = QuickAddParser.parse("Wind down every evening", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.kind, .habit)
        guard case .recurring(_, let timeOfDay) = result.schedule else { return XCTFail() }
        XCTAssertEqual(components(timeOfDay, [.hour]).hour, 18)
    }

    func testDailyKeyword() {
        let result = QuickAddParser.parse("Meditate daily", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.kind, .habit)
        guard case .recurring(let rule, _) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .daily)
        XCTAssertEqual(result.title, "Meditate")
    }

    func testWeeklyEverySundayAt5pm() {
        let result = QuickAddParser.parse("Weekly review every Sunday at 5pm", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.kind, .habit)
        guard case .recurring(let rule, let timeOfDay) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .weekly)
        XCTAssertEqual(rule.selectedWeekdays, [1])
        XCTAssertEqual(components(timeOfDay, [.hour]).hour, 17)
        XCTAssertEqual(result.title, "Weekly review")
    }

    func testEveryMondayHabit() {
        let result = QuickAddParser.parse("Plan week every Monday at 9am", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.kind, .habit)
        guard case .recurring(let rule, let timeOfDay) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .weekly)
        XCTAssertEqual(rule.selectedWeekdays, [2])
        XCTAssertEqual(components(timeOfDay, [.hour]).hour, 9)
    }

    func testEveryWeekdayHabit() {
        let result = QuickAddParser.parse("Standup every weekday at 10am", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.kind, .habit)
        guard case .recurring(let rule, let timeOfDay) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .weekdays)
        XCTAssertEqual(components(timeOfDay, [.hour]).hour, 10)
    }

    func testPayRentMonthly() {
        let result = QuickAddParser.parse("Pay rent on the 1st of every month", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.kind, .habit)
        guard case .recurring(let rule, let timeOfDay) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .monthly)
        XCTAssertEqual(components(timeOfDay, [.hour]).hour, 9)
        XCTAssertEqual(result.title, "Pay rent")
    }

    func testEveryMonthHabit() {
        let result = QuickAddParser.parse("Review subscriptions every month", now: makeNow(), calendar: calendar)
        guard case .recurring(let rule, _) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .monthly)
    }

    func testEveryYearHabit() {
        let result = QuickAddParser.parse("Renew passport every year", now: makeNow(), calendar: calendar)
        guard case .recurring(let rule, _) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .yearly)
    }

    func testTakeMedsTwiceDailyCustom() {
        let now = makeNow(hour: 11)
        let result = QuickAddParser.parse("Take meds twice daily", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .habit)
        guard case .recurring(let rule, let timeOfDay) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .custom)
        XCTAssertEqual(rule.customInterval, 2)
        XCTAssertEqual(rule.customFrequency, .daily)
        XCTAssertEqual(components(timeOfDay, [.hour]).hour, 11)
        XCTAssertEqual(result.title, "Take meds")
    }

    func testBiweeklyHabit() {
        let result = QuickAddParser.parse("Coffee chat biweekly", now: makeNow(), calendar: calendar)
        guard case .recurring(let rule, _) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .biweekly)
    }

    func testEveryOtherWeek() {
        let result = QuickAddParser.parse("Sync every other week", now: makeNow(), calendar: calendar)
        guard case .recurring(let rule, _) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .biweekly)
    }

    func testSubmitReportByFridayDueByEndOfDay() {
        let now = makeNow(year: 2025, month: 4, day: 16)
        let result = QuickAddParser.parse("Submit report by Friday", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .task)
        guard case .dueBy(let date) = result.schedule else { return XCTFail() }
        let c = components(date, [.weekday, .hour, .minute, .day])
        XCTAssertEqual(c.weekday, 6)
        XCTAssertEqual(c.day, 18)
        XCTAssertEqual(c.hour, 23)
        XCTAssertEqual(c.minute, 59)
        XCTAssertEqual(result.title, "Submit report")
    }

    func testShipV2ByApril30Milestone() {
        let now = makeNow(year: 2025, month: 4, day: 16)
        let result = QuickAddParser.parse("Ship v2 by April 30", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .milestone)
        guard case .targeting(let date) = result.schedule else { return XCTFail() }
        let c = components(date, [.year, .month, .day])
        XCTAssertEqual(c.year, 2025)
        XCTAssertEqual(c.month, 4)
        XCTAssertEqual(c.day, 30)
        XCTAssertEqual(result.title, "Ship v2")
    }

    func testMilestoneFallsBackToTaskIfClose() {
        let now = makeNow(year: 2025, month: 4, day: 16)
        let result = QuickAddParser.parse("Submit form by April 20", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .task)
        guard case .dueBy = result.schedule else { return XCTFail("Expected dueBy") }
    }

    func testMeetingThursday3pmForOneHour() {
        let now = makeNow(year: 2025, month: 4, day: 16)
        let result = QuickAddParser.parse("1:1 with Sara Thursday 3pm for 1 hour", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .event)
        guard case .at(let date, let duration) = result.schedule else { return XCTFail() }
        XCTAssertEqual(duration, 3600)
        let c = components(date, [.weekday, .hour, .minute, .day])
        XCTAssertEqual(c.weekday, 5)
        XCTAssertEqual(c.day, 17)
        XCTAssertEqual(c.hour, 15)
        XCTAssertEqual(c.minute, 0)
        XCTAssertEqual(result.title, "1:1 with Sara")
    }

    func testTodayDueBy() {
        let now = makeNow()
        let result = QuickAddParser.parse("Email John by today", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .task)
        guard case .dueBy(let date) = result.schedule else { return XCTFail() }
        let c = components(date, [.day, .hour])
        XCTAssertEqual(c.day, 16)
        XCTAssertEqual(c.hour, 23)
    }

    func testTomorrowDueBy() {
        let now = makeNow()
        let result = QuickAddParser.parse("Send invoice by tomorrow", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .task)
        guard case .dueBy(let date) = result.schedule else { return XCTFail() }
        XCTAssertEqual(components(date, [.day]).day, 17)
    }

    func testInThreeDays() {
        let now = makeNow()
        let result = QuickAddParser.parse("Reply to Anna in 3 days", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .task)
    }

    func testNextMondayWeekdayResolution() {
        let now = makeNow(year: 2025, month: 4, day: 16)
        let result = QuickAddParser.parse("Standup next Monday at 10am", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .event)
        guard case .at(let date, _) = result.schedule else { return XCTFail() }
        let c = components(date, [.weekday, .day])
        XCTAssertEqual(c.weekday, 2)
        XCTAssertEqual(c.day, 21)
    }

    func testNumericDateSlash() {
        let now = makeNow(year: 2025, month: 4, day: 16)
        let result = QuickAddParser.parse("Renew lease by 4/30", now: now, calendar: calendar)
        switch result.schedule {
        case .targeting(let date), .dueBy(let date):
            let c = components(date, [.month, .day])
            XCTAssertEqual(c.month, 4)
            XCTAssertEqual(c.day, 30)
        default:
            XCTFail("Expected target or due")
        }
    }

    func testNumericDateNonUSStyleDisambiguates() {
        let now = makeNow(year: 2025, month: 4, day: 16)
        let result = QuickAddParser.parse("Submit by 30/4", now: now, calendar: calendar)
        switch result.schedule {
        case .targeting(let date), .dueBy(let date):
            let c = components(date, [.month, .day])
            XCTAssertEqual(c.month, 4)
            XCTAssertEqual(c.day, 30)
        default:
            XCTFail("Expected a target or due date")
        }
    }

    func testAprilShortFormat() {
        let now = makeNow(year: 2025, month: 4, day: 16)
        let result = QuickAddParser.parse("Ship by Apr 30", now: now, calendar: calendar)
        switch result.schedule {
        case .targeting(let date), .dueBy(let date):
            let c = components(date, [.month, .day])
            XCTAssertEqual(c.month, 4)
            XCTAssertEqual(c.day, 30)
        default:
            XCTFail("Expected target or due")
        }
    }

    func testDayMonthLongFormat() {
        let now = makeNow(year: 2025, month: 1, day: 5)
        let result = QuickAddParser.parse("Call mom by 30 April", now: now, calendar: calendar)
        switch result.schedule {
        case .targeting(let date), .dueBy(let date):
            let c = components(date, [.month, .day, .year])
            XCTAssertEqual(c.month, 4)
            XCTAssertEqual(c.day, 30)
            XCTAssertEqual(c.year, 2025)
        default:
            XCTFail("Expected a target or due date")
        }
    }

    func testPastDateRollsToNextYear() {
        let now = makeNow(year: 2025, month: 6, day: 1)
        let result = QuickAddParser.parse("Renew by Apr 30", now: now, calendar: calendar)
        switch result.schedule {
        case .targeting(let date), .dueBy(let date):
            XCTAssertEqual(components(date, [.year]).year, 2026)
        default:
            XCTFail("Expected target or due")
        }
    }

    func testStandaloneDateBecomesTask() {
        let now = makeNow(year: 2025, month: 4, day: 16)
        let result = QuickAddParser.parse("Buy gift tomorrow", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .task)
        guard case .dueBy(let date) = result.schedule else { return XCTFail() }
        XCTAssertEqual(components(date, [.day]).day, 17)
    }

    func testLaunchVerbMakesMilestone() {
        let now = makeNow(year: 2025, month: 4, day: 16)
        let result = QuickAddParser.parse("Launch product by July 1", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .milestone)
    }

    func testFinishDraftByEndOfWeekDoesNotRecur() {
        let now = makeNow(year: 2025, month: 4, day: 16)
        let result = QuickAddParser.parse("Finish draft by Friday", now: now, calendar: calendar)
        XCTAssertEqual(result.kind, .task)
        guard case .dueBy = result.schedule else { return XCTFail() }
    }

    func testRecurrenceWinsOverTimeForHabitDetection() {
        let result = QuickAddParser.parse("Meditate daily at 7am", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.kind, .habit)
        guard case .recurring(let rule, let timeOfDay) = result.schedule else { return XCTFail() }
        XCTAssertEqual(rule.type, .daily)
        XCTAssertEqual(components(timeOfDay, [.hour]).hour, 7)
    }

    func testTitleStripsRecurrenceTokens() {
        let result = QuickAddParser.parse("Yoga every morning at 6am", now: makeNow(), calendar: calendar)
        XCTAssertEqual(result.title, "Yoga")
    }

    func testTitleStripsByClause() {
        let result = QuickAddParser.parse("Pay credit card by April 25", now: makeNow(year: 2025, month: 4, day: 16), calendar: calendar)
        XCTAssertEqual(result.title, "Pay credit card")
    }

    func testTitlePreservesPunctuation() {
        let result = QuickAddParser.parse("1:1 w/ Alex at 3pm", now: makeNow(hour: 8), calendar: calendar)
        XCTAssertTrue(result.title.contains("1:1"), "got: \(result.title)")
        XCTAssertTrue(result.title.contains("Alex"), "got: \(result.title)")
    }
}
