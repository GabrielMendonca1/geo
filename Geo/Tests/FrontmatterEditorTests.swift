import XCTest
@testable import Geo

final class FrontmatterEditorTests: XCTestCase {

    func testInsertsNewFieldIntoExistingFrontmatter() {
        let input = "---\nstate: Todo\n---\n# Body\n"
        let output = FrontmatterEditor.upsert(in: input, values: ["priority": .int(3)])
        let parsed = MarkdownConverter.shared.parse(output).frontmatter
        XCTAssertEqual(parsed["state"], "Todo")
        XCTAssertEqual(parsed["priority"], "3")
        XCTAssertTrue(output.contains("# Body"))
    }

    func testUpdatesExistingFieldValue() {
        let input = "---\nstate: Todo\npriority: 1\n---\n# Body\n"
        let output = FrontmatterEditor.upsert(in: input, values: ["state": .string("In Progress")])
        let parsed = MarkdownConverter.shared.parse(output).frontmatter
        XCTAssertEqual(parsed["state"], "In Progress")
        XCTAssertEqual(parsed["priority"], "1")
    }

    func testBuildsFreshFrontmatterWhenMissing() {
        let input = "# Just a body\n"
        let output = FrontmatterEditor.upsert(in: input, values: [
            "state": .string("Todo"),
            "priority": .int(2)
        ])
        XCTAssertTrue(output.hasPrefix("---\n"))
        let parsed = MarkdownConverter.shared.parse(output).frontmatter
        XCTAssertEqual(parsed["state"], "Todo")
        XCTAssertEqual(parsed["priority"], "2")
        XCTAssertTrue(output.contains("# Just a body"))
    }

    func testBuildsFreshFrontmatterOnEmptyMarkdown() {
        let output = FrontmatterEditor.upsert(in: "", values: ["state": .string("Todo")])
        XCTAssertTrue(output.hasPrefix("---\n"))
        XCTAssertTrue(output.contains("state: Todo"))
    }

    func testPreservesUnrelatedFrontmatterFields() {
        let input = "---\nstate: Todo\nlabels: [a, b]\nsymphony: true\n---\n# Body content\n\nSecond paragraph.\n"
        let output = FrontmatterEditor.upsert(in: input, values: ["state": .string("Done")])
        let parsed = MarkdownConverter.shared.parse(output).frontmatter
        XCTAssertEqual(parsed["state"], "Done")
        XCTAssertEqual(parsed["symphony"], "true")
        XCTAssertTrue(output.contains("labels: [a, b]"))
        XCTAssertTrue(output.contains("# Body content"))
        XCTAssertTrue(output.contains("Second paragraph."))
    }

    func testHandlesStringValueWithColon() {
        let input = "---\nstate: Todo\n---\n# Body\n"
        let output = FrontmatterEditor.upsert(in: input, values: [
            "url": .string("https://example.com/path")
        ])
        let parsed = MarkdownConverter.shared.parse(output).frontmatter
        XCTAssertEqual(parsed["url"], "https://example.com/path")
    }

    func testHandlesNullValueSerialization() {
        let input = "---\nstate: Todo\nsession: abc123\n---\n# Body\n"
        let output = FrontmatterEditor.upsert(in: input, values: ["session": .null])
        XCTAssertTrue(output.contains("session: "))
        XCTAssertFalse(output.contains("session: abc123"))
    }

    func testHandlesBoolAndIntScalars() {
        let input = "---\nstate: Todo\n---\n# Body\n"
        let output = FrontmatterEditor.upsert(in: input, values: [
            "active": .bool(true),
            "count": .int(42),
            "ratio": .double(0.5)
        ])
        let parsed = MarkdownConverter.shared.parse(output).frontmatter
        XCTAssertEqual(parsed["active"], "true")
        XCTAssertEqual(parsed["count"], "42")
        XCTAssertEqual(parsed["ratio"], "0.5")
    }

    func testHandlesArrayValue() {
        let input = "---\nstate: Todo\n---\n# Body\n"
        let output = FrontmatterEditor.upsert(in: input, values: [
            "labels": .array([.string("local"), .string("bug")])
        ])
        XCTAssertTrue(output.contains("labels: [local, bug]"))
    }

    func testHandlesLeadingBlankLinesBeforeFrontmatter() {
        let input = "\n\n---\nstate: Todo\n---\n# Body\n"
        let output = FrontmatterEditor.upsert(in: input, values: ["state": .string("Done")])
        let parsed = MarkdownConverter.shared.parse(output).frontmatter
        XCTAssertEqual(parsed["state"], "Done")
        XCTAssertTrue(output.contains("# Body"))
    }

    func testPreservesBodyExactlyOnUpsert() {
        let body = "# Heading\n\nSome paragraph.\n\n- list item 1\n- list item 2\n\n## Section\n\nMore text.\n"
        let input = "---\nstate: Todo\n---\n\(body)"
        let output = FrontmatterEditor.upsert(in: input, values: ["state": .string("Done")])
        XCTAssertTrue(output.hasSuffix(body))
    }

    func testUpsertScalarWithColonGetsQuotedAndRoundTrips() {
        let input = "---\nstate: Todo\n---\n# Body\n"
        let output = FrontmatterEditor.upsert(in: input, values: ["name": .string("Direito: oportunidade")])
        let parsed = MarkdownConverter.shared.parse(output).frontmatter
        XCTAssertEqual(parsed["name"], "Direito: oportunidade")
    }

    func testUpsertTagsInlineListRoundTrips() {
        let input = "---\nstate: Todo\n---\n# Body\n"
        let output = FrontmatterEditor.upsert(in: input, values: [
            "tags": .array([.string("arc"), .string("engenharia-de-software")])
        ])
        XCTAssertTrue(output.contains("tags: [arc, engenharia-de-software]"))
        let document = MarkdownConverter.shared.parse(output)
        XCTAssertEqual(MarkdownConverter.shared.frontmatterList(document, key: "tags"), ["arc", "engenharia-de-software"])
    }

    func testPreExistingBracketStringNotDoubleQuoted() {
        let input = "---\nstate: Todo\ntags: [a, b]\n---\n# Body\n"
        let output = FrontmatterEditor.upsert(in: input, values: ["state": .string("Done")])
        XCTAssertTrue(output.contains("tags: [a, b]"))
        XCTAssertFalse(output.contains("tags: \"[a, b]\""))
    }
}
