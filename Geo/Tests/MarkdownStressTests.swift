import XCTest
@testable import Geo

final class MarkdownStressTests: XCTestCase {

    // MARK: - Frontmatter

    func testFrontmatterCRLFRoundTrip() {
        let input = "---\r\nfoo: 1\r\n---\r\nhello\r\n"
        let doc = BlockEditorDocument(markdown: input)
        let out = doc.serialize()
        XCTAssertEqual(out, input, "CRLF must round-trip; splitFrontmatter currently drops \\r from rejoined frontmatter")
    }

    func testFrontmatterFabricatesNewline() {
        let input = "---\n---"
        let doc = BlockEditorDocument(markdown: input)
        let out = doc.serialize()
        XCTAssertEqual(out, input, "splitFrontmatter unconditionally appends \\n after closing --- and inflates byte count")
    }

    func testStateLinesAreDestroyed() {
        let input = "# Notes\n\nState: California\nPopulation: 39M\n"
        let doc = BlockEditorDocument(markdown: input)
        let out = doc.serialize()
        XCTAssertTrue(out.contains("State: California"),
                      "stripLegacySymphonyBodyMetadata deletes any body line starting with 'State:'; got: \(out)")
    }

    func testTripleNewlineCollapsedInsideCodeBlock() {
        let input = "```\nline1\n\n\nline2\n```\n"
        let doc = BlockEditorDocument(markdown: input)
        let out = doc.serialize()
        XCTAssertEqual(out, input,
                       "stripLegacySymphonyBodyMetadata blindly collapses \\n\\n\\n inside code blocks")
    }

    // MARK: - Callouts / toggles

    func testUnknownCalloutTypeLostOnEdit() {
        let input = "> [!foobar] Title\n> body line\n"
        let parsed = MarkdownBlockParser.parse(markdown: input)
        guard let callout = parsed.blocks.first, case .callout(let type, _) = callout.kind else {
            return XCTFail("expected a callout block, got \(parsed.blocks.map(\.kind))")
        }
        XCTAssertEqual(type, .note, "unknown types coerce to .note (sanity)")
        let edited = callout.withCalloutContent("new body")
        XCTAssertTrue(edited.rawText.contains("[!foobar]"),
                      "round-trip after edit should preserve original [!foobar]; got: \(edited.rawText)")
    }

    func testToggleStateSwapFailsWithSpacedSyntax() {
        let input = ">> [v] Daily plan\n>> body\n"
        let parsed = MarkdownBlockParser.parse(markdown: input)
        guard let toggle = parsed.blocks.first, case .toggle(let expanded) = toggle.kind else {
            return XCTFail("expected toggle, got \(parsed.blocks.map(\.kind))")
        }
        XCTAssertTrue(expanded, "v means expanded")
        let collapsed = toggle.withToggleState(expanded: false)
        XCTAssertTrue(collapsed.rawText.contains("[>]"),
                      "withToggleState should flip marker; replacingOccurrences pattern is '>>[v]' which doesn't match spaced syntax '>> [v]'. got: \(collapsed.rawText)")
    }

    // MARK: - Code blocks

    func testNestedFencedCodeBlockSplits() {
        let input = "````md\n```swift\ninner\n```\n````\n"
        let parsed = MarkdownBlockParser.parse(markdown: input)
        let codeBlocks = parsed.blocks.filter {
            if case .codeBlock = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(codeBlocks.count, 1,
                       "expected one outer code block; got \(codeBlocks.count) (parser closes outer fence on inner ``` prefix)")
    }

    func testCodeFenceTrailingSpaceLost() {
        let parsed = MarkdownBlockParser.parse(markdown: "```swift   \nx\n```\n")
        guard let code = parsed.blocks.first else {
            return XCTFail("expected a code block")
        }
        let edited = code.withCodeContent("y")
        XCTAssertFalse(edited.rawText.hasPrefix("```swift\n"),
                       "withCodeContent should preserve original opener spacing; collapses to '```swift\\n'. got: \(edited.rawText)")
    }

    // MARK: - Tables

    func testSingleBarLineBecomesTable() {
        let input = "|im paranoid|\n"
        let parsed = MarkdownBlockParser.parse(markdown: input)
        XCTAssertEqual(parsed.blocks.count, 1)
        if case .table = parsed.blocks[0].kind {
            XCTFail("a single bar-wrapped line is not a valid table; parser greedily promotes it")
        }
    }

    // MARK: - Horizontal rule detection

    func testTwoDashIsNotHorizontalRule() {
        XCTAssertFalse(MarkdownBlockParser.isHorizontalRule("--"))
    }

    func testSpacedDashesAreHorizontalRule() {
        XCTAssertTrue(MarkdownBlockParser.isHorizontalRule("- - -"),
                      "CommonMark allows spaces between HR chars")
    }

    // MARK: - Bullet depth

    func testBulletDepthClampedByPrecedingParagraph() {
        let input = "Some paragraph\n        - deeply indented bullet\n"
        let parsed = MarkdownBlockParser.parse(markdown: input)
        guard parsed.blocks.count == 2 else {
            return XCTFail("expected 2 blocks, got \(parsed.blocks.count): \(parsed.blocks.map(\.kind))")
        }
        let depth = parsed.blocks[1].depth
        XCTAssertGreaterThanOrEqual(depth, 2,
                                    "8 spaces should yield depth 4 (raw); paragraph predecessor clamps to 1. got depth=\(depth)")
    }

    // MARK: - Image fallback

    func testImageUrlWithParensFallsBackToParagraph() {
        let input = "![alt](path (with parens).png)\n"
        let parsed = MarkdownBlockParser.parse(markdown: input)
        XCTAssertEqual(parsed.blocks.count, 1)
        if case .image = parsed.blocks[0].kind {
            XCTFail("parens in URL should ideally be handled, currently falls through to paragraph — this test pins the gap")
        }
        XCTAssertEqual(parsed.blocks[0].kind, .paragraph,
                       "regex `[^)]+` for URL stops at first paren; line becomes a paragraph")
    }

    // MARK: - mergeIdentity drift

    func testMergeIdentityDriftsOnDuplicateContent() {
        // Two identical paragraphs; user collapses the SECOND one (id=B).
        let parsedA = MarkdownBlockParser.parse(markdown: "same line\nsame line\n")
        var blocksA = parsedA.blocks
        guard blocksA.count == 2 else {
            return XCTFail("expected 2 blocks; got \(blocksA.count): \(blocksA.map(\.kind))")
        }
        let idA = blocksA[0].id
        let idB = blocksA[1].id
        blocksA[1].collapsed = true
        let docOld = BlockDocument(blocks: blocksA, source: "")

        // External edit: user swaps order. Both new blocks are byte-identical
        // to both old blocks, so the exact-match phase in mergeIdentity matches
        // by FIRST UNCONSUMED — new[0] grabs old[0] (id=A, uncollapsed) and
        // new[1] grabs old[1] (id=B, collapsed). The collapsed flag (and id B)
        // stays at index 1, even though the user "moved" the collapsed line
        // to index 0. Identity does not follow content rearrangement when
        // content is duplicated.
        let docNew = MarkdownBlockParser.parse(markdown: "same line\nsame line\n")

        let merged = MarkdownBlockParser.mergeIdentity(old: docOld, new: docNew)
        XCTAssertEqual(merged.blocks.count, 2)
        // The two old IDs both survive — but on which slots?
        XCTAssertEqual(merged.blocks[0].id, idA)
        XCTAssertEqual(merged.blocks[1].id, idB)
        // This assertion documents the issue rather than asserting the "fixed"
        // behavior — for an external reorder of identical lines, merge cannot
        // recover the user's intent. The bug surfaces when the user genuinely
        // moved a block: pinning behavior here so any future change is visible.
        XCTAssertTrue(merged.blocks[1].collapsed,
                      "collapsed flag pins to position, not content; if this ever flips, document the change in mergeIdentity")
    }
}
