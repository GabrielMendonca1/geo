import XCTest
@testable import Garime

private let santanderStatement = """
OFXHEADER:100
DATA:OFXSGML
VERSION:102
CHARSET:1252

<OFX>
<BANKMSGSRSV1><STMTTRNRS><STMTRS>
<CURDEF>BRL
<BANKACCTFROM><BANKID>033<ACCTID>0001234567<ACCTTYPE>CHECKING</BANKACCTFROM>
<BANKTRANLIST>
<DTSTART>20260801<DTEND>20260831
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260805120000[-3:BRT]
<TRNAMT>-53.90
<FITID>2026080500001
<MEMO>IFOOD *IFOOD SAO PAULO
</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260806
<TRNAMT>-312.45
<FITID>2026080600002
<MEMO>SUPERMERCADO PAO DE ACUCAR
</STMTTRN>
<STMTTRN>
<TRNTYPE>CREDIT
<DTPOSTED>20260805
<TRNAMT>7500.00
<FITID>2026080500003
<MEMO>PAGAMENTO DE SALARIO
</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260810
<TRNAMT>-99.90
<FITID>2026081000004
<MEMO>SMART FIT ACADEMIA
</STMTTRN>
</BANKTRANLIST>
</STMTRS></STMTTRNRS></BANKMSGSRSV1>
</OFX>
"""

final class OFXParserTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }()

    func testReadsEveryTransactionOfTheStatement() {
        let transactions = OFXParser.parse(text: santanderStatement, calendar: calendar)
        XCTAssertEqual(transactions.count, 4)
        XCTAssertEqual(transactions.first?.fitid, "2026080500001")
        XCTAssertEqual(transactions.first?.amount, Decimal(string: "-53.90"))
        XCTAssertEqual(transactions.first?.memo, "IFOOD *IFOOD SAO PAULO")
    }

    func testParsesDateWithTimezoneSuffix() {
        let date = OFXParser.date(from: "20260805120000[-3:BRT]", calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day], from: XCTUnwrap2(date))
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 5)
    }

    func testAcceptsCommaDecimalAndRejectsGarbage() {
        XCTAssertEqual(OFXParser.amount(from: "-1.234,56"), Decimal(string: "-1234.56"))
        XCTAssertEqual(OFXParser.amount(from: "-53.90"), Decimal(string: "-53.90"))
        XCTAssertNil(OFXParser.amount(from: "abc"))
    }

    func testReadsLatin1FileWithAccents() {
        let text = santanderStatement.replacingOccurrences(of: "PAGAMENTO DE SALARIO", with: "SALÁRIO MENSÁL")
        let data = text.data(using: .isoLatin1)!
        let transactions = OFXParser.parse(data, calendar: calendar)
        XCTAssertEqual(transactions.count, 4)
        XCTAssertTrue(transactions.contains { $0.memo.contains("SALÁRIO") })
    }

    func testEmptyOrBrokenFileYieldsNothingInsteadOfCrashing() {
        XCTAssertTrue(OFXParser.parse(text: "", calendar: calendar).isEmpty)
        XCTAssertTrue(OFXParser.parse(text: "<STMTTRN><MEMO>sem data nem valor</STMTTRN>", calendar: calendar).isEmpty)
    }

    private func XCTUnwrap2(_ date: Date?) -> Date {
        guard let date else {
            XCTFail("data não parseada")
            return Date()
        }
        return date
    }
}

final class MoneyImportMappingTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }()

    func testSignBecomesKindAndAmountIsAlwaysPositive() {
        let entries = MoneyImport.entries(from: OFXParser.parse(text: santanderStatement, calendar: calendar))
        let ifood = entries.first { $0.note.contains("IFOOD") }
        let salary = entries.first { $0.note.contains("SALARIO") }

        XCTAssertEqual(ifood?.kind, .expense)
        XCTAssertEqual(ifood?.amount, Decimal(string: "53.90"))
        XCTAssertEqual(salary?.kind, .income)
        XCTAssertEqual(salary?.amount, 7500)
        XCTAssertTrue(entries.allSatisfy { $0.amount > 0 })
    }

    func testCategoryIsGuessedFromTheStatementText() {
        let entries = MoneyImport.entries(from: OFXParser.parse(text: santanderStatement, calendar: calendar))
        XCTAssertEqual(entries.first { $0.note.contains("IFOOD") }?.category, "comida")
        XCTAssertEqual(entries.first { $0.note.contains("PAO DE ACUCAR") }?.category, "mercado")
        XCTAssertEqual(entries.first { $0.note.contains("SMART FIT") }?.category, "academia")
        XCTAssertEqual(entries.first { $0.note.contains("SALARIO") }?.category, "salário")
    }

    func testUnknownMerchantFallsBackToOutro() {
        XCTAssertEqual(MoneyCategoryGuess.category(for: "PIX ENVIADO FULANO", kind: .expense), "outro")
    }
}

@MainActor
final class MoneyImportStoreTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }()

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("money-import-\(UUID().uuidString).json")
    }

    private var imported: [MoneyEntry] {
        MoneyImport.entries(from: OFXParser.parse(text: santanderStatement, calendar: calendar))
    }

    func testImportingTheSameStatementTwiceDoesNotDuplicate() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MoneyStore(fileURL: url)

        let first = store.importEntries(imported)
        XCTAssertEqual(first.added, 4)
        XCTAssertEqual(first.skipped, 0)

        let second = store.importEntries(imported)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.skipped, 4)
        XCTAssertEqual(store.entries.count, 4)
    }

    func testDeduplicationSurvivesAppRestart() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        MoneyStore(fileURL: url).importEntries(imported)
        let reopened = MoneyStore(fileURL: url)
        XCTAssertEqual(reopened.importEntries(imported).added, 0)
        XCTAssertEqual(reopened.entries.count, 4)
    }

    func testManualEntriesWithoutFitidAreNeverDeduplicated() {
        let store = MoneyStore(fileURL: temporaryURL())
        let manual = MoneyEntry(kind: .expense, amount: 10, category: "comida")
        store.importEntries([manual])
        store.importEntries([manual])
        XCTAssertEqual(store.entries.count, 2, "sem FITID não há como saber que é repetido")
    }

    func testImportedEntriesJoinTheMonthProjection() {
        let store = MoneyStore(fileURL: temporaryURL())
        store.importEntries(imported)
        let august = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 12))!
        let summary = MoneyMath.summary(of: MoneyMath.entries(store.entries, inMonthOf: august, calendar: calendar))
        XCTAssertEqual(summary.income, 7500)
        XCTAssertEqual(summary.expense, Decimal(string: "466.25"))
    }
}
