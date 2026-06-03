import XCTest
@testable import Geo

final class FrontmatterYAMLRoundTripTests: XCTestCase {

    private func assertScalarRoundTrips(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let emitted = FrontmatterYAML.emitScalar(value)
        let parsed = FrontmatterYAML.parseScalar(emitted)
        XCTAssertEqual(parsed, value, "scalar round-trip failed for \(value.debugDescription) (emitted: \(emitted.debugDescription))", file: file, line: line)
    }

    private func assertListRoundTrips(_ list: [String], file: StaticString = #filePath, line: UInt = #line) {
        let emitted = FrontmatterYAML.emitInlineList(list)
        let parsed = FrontmatterYAML.parseInlineList(emitted)
        XCTAssertEqual(parsed, list, "list round-trip failed for \(list) (emitted: \(emitted))", file: file, line: line)
    }

    func testScalarRoundTrips() {
        assertScalarRoundTrips("Direito: oportunidade")
        assertScalarRoundTrips("a, b, c")
        assertScalarRoundTrips("arr[0]")
        assertScalarRoundTrips("#pkm")
        assertScalarRoundTrips("she said \"hi\"")
        assertScalarRoundTrips("it's")
        assertScalarRoundTrips("Introdução à Engenharia")
        assertScalarRoundTrips(" x ")
        assertScalarRoundTrips("")
    }

    func testReservedAndNumericScalarsAreQuotedAndReadBackAsStrings() {
        for value in ["true", "false", "null", "yes", "no", "~", "123", "1.5"] {
            XCTAssertTrue(FrontmatterYAML.needsQuoting(value), "\(value) should be quoted")
            assertScalarRoundTrips(value)
        }
    }

    func testListRoundTrips() {
        assertListRoundTrips([])
        assertListRoundTrips(["a"])
        assertListRoundTrips(["arc", "engenharia-de-software"])
        assertListRoundTrips(["Direito: oportunidade", "arc"])
        assertListRoundTrips(["a, b", "c"])
    }

    func testSimpleScalarsAreNotQuoted() {
        XCTAssertEqual(FrontmatterYAML.emitScalar("fleeting"), "fleeting")
        XCTAssertEqual(FrontmatterYAML.emitScalar("active"), "active")
        XCTAssertEqual(FrontmatterYAML.emitScalar("engenharia-de-software"), "engenharia-de-software")
    }

    func testInlineListEmitsUnquotedSimpleElements() {
        XCTAssertEqual(FrontmatterYAML.emitInlineList(["local", "bug"]), "[local, bug]")
        XCTAssertEqual(FrontmatterYAML.emitInlineList([]), "[]")
    }

    func testParseInlineListReturnsNilForNonBracketed() {
        XCTAssertNil(FrontmatterYAML.parseInlineList("not a list"))
        XCTAssertNil(FrontmatterYAML.parseInlineList("active"))
    }

    func testQuoteAwareCommaSplit() {
        XCTAssertEqual(FrontmatterYAML.parseInlineList("[\"a, b\", c]"), ["a, b", "c"])
    }

    func testLiveCorpusShapeRoundTripsByteIdentical() {
        let input = "---\nfrontmatter_version: 2\ntype: fleeting\nstatus: active\n---\n# Body\n"
        let document = MarkdownConverter.shared.parse(input)
        var out = "---\n"
        for key in ["frontmatter_version", "type", "status"] {
            out += "\(key): \(FrontmatterYAML.emitScalar(key: key, value: document.frontmatter[key]!))\n"
        }
        out += "---\n" + document.body
        XCTAssertEqual(out, input)
    }
}
