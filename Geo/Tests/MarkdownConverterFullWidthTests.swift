import XCTest
@testable import Geo

final class MarkdownConverterFullWidthTests: XCTestCase {
    private let converter = MarkdownConverter.shared

    func testFullWidthTrueReadsTrue() {
        let md = "---\ntype: fleeting\nfull_width: true\n---\n# Wide\n"
        XCTAssertTrue(converter.fullWidth(in: md))
    }

    func testFullWidthAbsentReadsFalse() {
        let md = "---\ntype: fleeting\n---\n# Narrow\n"
        XCTAssertFalse(converter.fullWidth(in: md))
    }

    func testFullWidthFalseReadsFalse() {
        let md = "---\ntype: fleeting\nfull_width: false\n---\n# Narrow\n"
        XCTAssertFalse(converter.fullWidth(in: md))
    }

    func testFullWidthToleratesQuotesAndCase() {
        XCTAssertTrue(converter.fullWidth(in: "---\nfull_width: \"True\"\n---\nx"))
        XCTAssertTrue(converter.fullWidth(in: "---\nfull_width: 'TRUE'\n---\nx"))
        XCTAssertTrue(converter.fullWidth(in: "---\nfull_width: yes\n---\nx"))
        XCTAssertFalse(converter.fullWidth(in: "---\nfull_width: \"no\"\n---\nx"))
    }

    func testNoFrontmatterReadsFalse() {
        XCTAssertFalse(converter.fullWidth(in: "# Just a body\nfull_width: true"))
    }

    func testEmitScalarBooleanKeyNormalizes() {
        XCTAssertEqual(FrontmatterYAML.emitScalar(key: "full_width", value: "true"), "true")
        XCTAssertEqual(FrontmatterYAML.emitScalar(key: "full_width", value: "False"), "false")
    }
}
