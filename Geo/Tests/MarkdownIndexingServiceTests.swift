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

    func testExtractDayIdsFromBodyWikilinks() {
        let markdown = "Logged this on [[2026-06-03]] for the record."

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.dayIds, ["2026-06-03"])
    }

    func testExtractDayIdsHandlesAliasedAndDedupes() {
        let markdown = "see [[2026-06-03|today]] and again [[2026-06-03]]"

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.dayIds, ["2026-06-03"])
    }

    func testExtractDayIdsRejectsInvalidDates() {
        let markdown = "bad date [[2026-13-99]] should not index"

        let result = sut.extract(from: markdown)

        XCTAssertTrue(result.dayIds.isEmpty)
    }

    func testExtractDayIdsIgnoresCodeBlocks() {
        let markdown = """
        ```
        [[2026-06-03]]
        ```
        """

        let result = sut.extract(from: markdown)

        XCTAssertTrue(result.dayIds.isEmpty)
    }

    func testExtractMergesFrontmatterTagsWithBodyHashtags() {
        let markdown = """
        ---
        tags: [arc, pkm]
        ---
        body #pkm #swift
        """

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.tags, ["arc", "pkm", "swift"])
    }

    func testExtractFrontmatterTagsCaseFoldedToMatchBlockTags() {
        let markdown = """
        ---
        tags: [ARC]
        ---
        body
        """

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.tags, ["arc"])
    }

    func testExtractSurfacesFrontmatterId() {
        let markdown = """
        ---
        id: 7f3a1b2c-0000-4000-8000-000000000001
        ---
        body
        """

        let result = sut.extract(from: markdown)

        XCTAssertEqual(result.frontmatterId, "7f3a1b2c-0000-4000-8000-000000000001")
    }

    func testExtractFrontmatterIdAbsentIsNil() {
        let markdown = """
        ---
        type: fleeting
        ---
        body
        """

        let result = sut.extract(from: markdown)

        XCTAssertNil(result.frontmatterId)
    }
}
