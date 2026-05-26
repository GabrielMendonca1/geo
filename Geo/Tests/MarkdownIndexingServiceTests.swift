import XCTest
@testable import Geo

final class MarkdownIndexingServiceTests: XCTestCase {
    private var sut: MarkdownIndexingService!

    override func setUp() {
        super.setUp()
        sut = MarkdownIndexingService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func testExtractTagsNormalizesLowercaseUniqueAndSorted() {
        let markdown = "#Swift #ios #swift #App"

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.tags, ["app", "ios", "swift"])
    }

    func testExtractIgnoresInlineCodeTags() {
        let markdown = "real #visible and `#hidden`"

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.tags, ["visible"])
    }

    func testExtractIgnoresFencedCodeBlockTags() {
        let markdown = """
        #top
        ```swift
        let value = \"#hidden\"
        ```
        #bottom
        """

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.tags, ["bottom", "top"])
    }

    func testExtractCountsOpenChecklistItemsForBullets() {
        let markdown = """
        - [ ] one
        * [ ] two
        + [ ] three
        """

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.openTaskCount, 3)
        XCTAssertEqual(result.completedTaskCount, 0)
    }

    func testExtractCountsCompletedChecklistItemsForUpperAndLowerX() {
        let markdown = """
        - [x] done one
        - [X] done two
        """

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.completedTaskCount, 2)
        XCTAssertEqual(result.openTaskCount, 0)
    }

    func testExtractCountsOrderedChecklistItems() {
        let markdown = """
        1. [ ] open
        2. [x] done
        """

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.openTaskCount, 1)
        XCTAssertEqual(result.completedTaskCount, 1)
    }

    func testExtractFromMarkdownParsesFrontmatterAndIndexesBodyOnly() {
        let markdown = """
        ---
        title: #not-a-tag
        ---
        body #real
        """

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.tags, ["real"])
    }

    func testExtractReturnsEmptyCountsForPlainText() {
        let markdown = "This is plain text without checklist items."

        let result = sut.extract(from: markdown)

        XCTAssertTrue(result.tags.isEmpty)
        XCTAssertEqual(result.openTaskCount, 0)
        XCTAssertEqual(result.completedTaskCount, 0)
    }
}
