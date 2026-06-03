import XCTest
@testable import Geo

final class FrontmatterBlockBuilderTests: XCTestCase {

    func testBasicBlockParsesBack() {
        let block = FrontmatterBlockBuilder.block(
            id: "abc-123",
            type: "permanent",
            status: "evergreen",
            layer: "agent",
            tags: ["arc"],
            fullWidth: true
        )
        let doc = MarkdownConverter.shared.parse(block + "# Body\n")
        XCTAssertEqual(doc.frontmatter["id"], "abc-123")
        XCTAssertEqual(doc.frontmatter["type"], "permanent")
        XCTAssertEqual(doc.frontmatter["status"], "evergreen")
        XCTAssertEqual(doc.frontmatter["layer"], "agent")
        XCTAssertEqual(doc.frontmatter["full_width"], "true")
        XCTAssertEqual(MarkdownConverter.shared.frontmatterList(doc, key: "tags"), ["arc"])
    }

    func testStatusOmittedWhenNilOrEmpty() {
        let nilStatus = FrontmatterBlockBuilder.block(id: nil, type: "fleeting", status: nil, layer: "user", tags: [], fullWidth: false)
        XCTAssertFalse(nilStatus.contains("status"))
        let emptyStatus = FrontmatterBlockBuilder.block(id: nil, type: "fleeting", status: "", layer: "user", tags: [], fullWidth: false)
        XCTAssertFalse(emptyStatus.contains("status"))
    }

    func testTagsOmittedWhenEmptyAndFullWidthOmittedWhenFalse() {
        let block = FrontmatterBlockBuilder.block(id: nil, type: "fleeting", status: nil, layer: "user", tags: [], fullWidth: false)
        XCTAssertFalse(block.contains("tags"))
        XCTAssertFalse(block.contains("full_width"))
    }

    func testIdOmittedWhenNil() {
        let block = FrontmatterBlockBuilder.block(id: nil, type: "fleeting", status: nil, layer: "user", tags: [], fullWidth: false)
        XCTAssertFalse(block.contains("id:"))
    }

    func testPlainTagStaysUnquoted() {
        let block = FrontmatterBlockBuilder.block(id: nil, type: "fleeting", status: nil, layer: "user", tags: ["arc"], fullWidth: false)
        XCTAssertTrue(block.contains("tags: [arc]"))
    }

    func testSingleElementList() {
        let block = FrontmatterBlockBuilder.block(id: nil, type: "fleeting", status: nil, layer: "user", tags: ["x"], fullWidth: false)
        XCTAssertTrue(block.contains("tags: [x]"))
    }

    func testColonTagRoundTrips() {
        let block = FrontmatterBlockBuilder.block(id: nil, type: "fleeting", status: nil, layer: "user", tags: ["Direito: oportunidade"], fullWidth: false)
        let doc = MarkdownConverter.shared.parse(block + "# B\n")
        XCTAssertEqual(MarkdownConverter.shared.frontmatterList(doc, key: "tags"), ["Direito: oportunidade"])
    }

    func testCommaAndAccentTagsRoundTrip() {
        let tags = ["a, b", "Introdução"]
        let block = FrontmatterBlockBuilder.block(id: nil, type: "fleeting", status: nil, layer: "user", tags: tags, fullWidth: false)
        let doc = MarkdownConverter.shared.parse(block + "# B\n")
        XCTAssertEqual(MarkdownConverter.shared.frontmatterList(doc, key: "tags"), tags)
    }

    func testBracketAndQuoteTagsRoundTrip() {
        let tags = ["arr[0]", "she said \"hi\""]
        let block = FrontmatterBlockBuilder.block(id: nil, type: "fleeting", status: nil, layer: "user", tags: tags, fullWidth: false)
        let doc = MarkdownConverter.shared.parse(block + "# B\n")
        XCTAssertEqual(MarkdownConverter.shared.frontmatterList(doc, key: "tags"), tags)
    }
}
