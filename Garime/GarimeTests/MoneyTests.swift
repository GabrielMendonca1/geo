import XCTest
@testable import Garime

final class MoneyAmountTests: XCTestCase {
    func testParsesBrazilianTyping() {
        XCTAssertEqual(MoneyAmount.parse("12,50"), Decimal(string: "12.50"))
        XCTAssertEqual(MoneyAmount.parse("1.200,90"), Decimal(string: "1200.90"))
        XCTAssertEqual(MoneyAmount.parse("R$ 30"), 30)
        XCTAssertEqual(MoneyAmount.parse("12.50"), Decimal(string: "12.50"))
    }

    func testRejectsGarbageAndNonPositive() {
        XCTAssertNil(MoneyAmount.parse(""))
        XCTAssertNil(MoneyAmount.parse("abc"))
        XCTAssertNil(MoneyAmount.parse("0"))
        XCTAssertNil(MoneyAmount.parse("-10"))
    }
}

final class MoneyMathTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }()

    private func date(_ day: Int, month: Int = 8, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testSummarySplitsIncomeFromExpense() {
        let entries = [
            MoneyEntry(date: date(2), kind: .income, amount: 5000, category: "salário"),
            MoneyEntry(date: date(3), kind: .expense, amount: 200, category: "mercado"),
            MoneyEntry(date: date(4), kind: .expense, amount: 50, category: "comida"),
        ]
        let summary = MoneyMath.summary(of: entries)
        XCTAssertEqual(summary.income, 5000)
        XCTAssertEqual(summary.expense, 250)
        XCTAssertEqual(summary.balance, 4750)
    }

    func testOnlyCurrentMonthEntriesCount() {
        let entries = [
            MoneyEntry(date: date(10, month: 8), kind: .expense, amount: 100, category: "mercado"),
            MoneyEntry(date: date(10, month: 7), kind: .expense, amount: 999, category: "mercado"),
        ]
        let month = MoneyMath.entries(entries, inMonthOf: date(20, month: 8), calendar: calendar)
        XCTAssertEqual(month.count, 1)
        XCTAssertEqual(MoneyMath.summary(of: month).expense, 100)
    }

    func testRecurringCountsWholeAndVariableFollowsPace() {
        // Dia 10 de agosto (31 dias): ritmo = 31/10 = 3.1
        let now = date(10)
        let entries = [
            MoneyEntry(date: date(1), kind: .income, amount: 5000, category: "salário", recurring: true),
            MoneyEntry(date: date(1), kind: .expense, amount: 2000, category: "casa", recurring: true),
            MoneyEntry(date: date(5), kind: .expense, amount: 100, category: "comida"),
        ]
        let projection = MoneyMath.projection(for: entries, now: now, calendar: calendar)

        XCTAssertEqual(projection.realized.expense, 2100)
        XCTAssertEqual(projection.projectedIncome, 5000, "recorrente não é extrapolado")
        XCTAssertEqual(projection.projectedExpense, Decimal(string: "2310")!, "2000 fixo + 100 * 3.1")
        XCTAssertEqual(projection.projectedBalance, Decimal(string: "2690")!)
    }

    func testEmptyMonthProjectsZeroWithoutDividingByZero() {
        let projection = MoneyMath.projection(for: [], now: date(1), calendar: calendar)
        XCTAssertEqual(projection.projectedIncome, 0)
        XCTAssertEqual(projection.projectedExpense, 0)
        XCTAssertEqual(projection.projectedBalance, 0)
    }
}

@MainActor
final class MoneyStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("money-test-\(UUID().uuidString).json")
    }

    func testEntriesSurviveAReload() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = MoneyStore(fileURL: url)
        store.add(MoneyEntry(kind: .expense, amount: Decimal(string: "42.90")!, category: "mercado", note: "feira"))

        let reopened = MoneyStore(fileURL: url)
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entries.first?.amount, Decimal(string: "42.90"))
        XCTAssertEqual(reopened.entries.first?.category, "mercado")
        XCTAssertEqual(reopened.entries.first?.note, "feira")
    }

    func testDeleteRemovesFromDisk() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = MoneyStore(fileURL: url)
        let entry = MoneyEntry(kind: .income, amount: 100, category: "freela")
        store.add(entry)
        store.delete(entry)

        XCTAssertTrue(MoneyStore(fileURL: url).entries.isEmpty)
    }

    func testNewestEntryComesFirst() {
        let store = MoneyStore(fileURL: temporaryURL())
        let old = MoneyEntry(date: Date().addingTimeInterval(-86_400), kind: .expense, amount: 10, category: "comida")
        let new = MoneyEntry(date: Date(), kind: .expense, amount: 20, category: "mercado")
        store.add(old)
        store.add(new)
        XCTAssertEqual(store.entries.first?.id, new.id)
    }
}
