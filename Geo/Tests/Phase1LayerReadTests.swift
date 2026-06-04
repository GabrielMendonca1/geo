import XCTest
@testable import Geo

final class Phase1LayerReadTests: XCTestCase {

    // MARK: - MarkdownConverter.normalizedLayer / layer(in:)

    func testNormalizedLayerReturnsNilForAbsentAndEmpty() {
        XCTAssertNil(MarkdownConverter.normalizedLayer(nil))
        XCTAssertNil(MarkdownConverter.normalizedLayer(""))
        XCTAssertNil(MarkdownConverter.normalizedLayer("   "))
    }

    func testNormalizedLayerParsesEachRawValue() {
        XCTAssertEqual(MarkdownConverter.normalizedLayer("user"), .user)
        XCTAssertEqual(MarkdownConverter.normalizedLayer("agent"), .agent)
        XCTAssertEqual(MarkdownConverter.normalizedLayer("review"), .review)
        XCTAssertEqual(MarkdownConverter.normalizedLayer("shared"), .shared)
    }

    func testNormalizedLayerToleratesQuotesAndCase() {
        XCTAssertEqual(MarkdownConverter.normalizedLayer("\"agent\""), .agent)
        XCTAssertEqual(MarkdownConverter.normalizedLayer("'shared'"), .shared)
        XCTAssertEqual(MarkdownConverter.normalizedLayer("AGENT"), .agent)
        XCTAssertEqual(MarkdownConverter.normalizedLayer(" Review "), .review)
    }

    func testNormalizedLayerReturnsNilForInvalidValue() {
        XCTAssertNil(MarkdownConverter.normalizedLayer("bogus"))
        XCTAssertNil(MarkdownConverter.normalizedLayer("Voce"))
    }

    func testLayerInReturnsNilWhenNoFrontmatter() {
        XCTAssertNil(MarkdownConverter.shared.layer(in: "# Just a heading\n\nBody.\n"))
    }

    func testLayerInReturnsNilWhenFrontmatterLacksLayer() {
        XCTAssertNil(MarkdownConverter.shared.layer(in: "---\ntype: fleeting\n---\n# X\n"))
    }

    func testLayerInParsesPresentLayer() {
        XCTAssertEqual(MarkdownConverter.shared.layer(in: "---\nlayer: shared\n---\n# X\n"), .shared)
    }
}
