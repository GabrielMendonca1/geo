import XCTest
@testable import Geo

final class BlockModelTests: XCTestCase {

    // MARK: - Parse block kinds

    func testParseHeading() {
        let doc = MarkdownBlockParser.parse(markdown: "# Hello\n")
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(doc.blocks[0].prefix, "# ")
    }

    func testParseHeadingLevel3() {
        let doc = MarkdownBlockParser.parse(markdown: "### Third\n")
        XCTAssertEqual(doc.blocks[0].kind, .heading(level: 3))
        XCTAssertEqual(doc.blocks[0].prefix, "### ")
    }

    func testParseBlockquote() {
        let doc = MarkdownBlockParser.parse(markdown: "> quote text\n")
        XCTAssertEqual(doc.blocks[0].kind, .blockquote)
        XCTAssertEqual(doc.blocks[0].prefix, "> ")
    }

    func testParseNestedBlockquote() {
        let doc = MarkdownBlockParser.parse(markdown: "> > nested\n")
        XCTAssertEqual(doc.blocks[0].kind, .blockquote)
        XCTAssertEqual(doc.blocks[0].prefix, "> > ")
    }

    func testParseBulletItem() {
        let doc = MarkdownBlockParser.parse(markdown: "- item\n")
        XCTAssertEqual(doc.blocks[0].kind, .bulletItem(marker: "-"))
        XCTAssertEqual(doc.blocks[0].prefix, "- ")
    }

    func testParseOrderedItem() {
        let doc = MarkdownBlockParser.parse(markdown: "3. item\n")
        XCTAssertEqual(doc.blocks[0].kind, .orderedItem(number: 3))
        XCTAssertEqual(doc.blocks[0].prefix, "3. ")
    }

    func testParseCheckboxUnchecked() {
        let doc = MarkdownBlockParser.parse(markdown: "- [ ] todo\n")
        XCTAssertEqual(doc.blocks[0].kind, .checkboxItem(checked: false, marker: "-"))
        XCTAssertEqual(doc.blocks[0].prefix, "- [ ] ")
    }

    func testParseCheckboxChecked() {
        let doc = MarkdownBlockParser.parse(markdown: "- [x] done\n")
        XCTAssertEqual(doc.blocks[0].kind, .checkboxItem(checked: true, marker: "-"))
    }

    func testParseIndentedBullet() {
        let doc = MarkdownBlockParser.parse(markdown: "  - nested\n")
        XCTAssertEqual(doc.blocks[0].kind, .bulletItem(marker: "-"))
        XCTAssertEqual(doc.blocks[0].indent, "  ")
        XCTAssertEqual(doc.blocks[0].prefix, "  - ")
    }

    func testParseHorizontalRule() {
        let doc = MarkdownBlockParser.parse(markdown: "---\n")
        XCTAssertEqual(doc.blocks[0].kind, .horizontalRule)
    }

    func testParseCodeBlock() {
        let doc = MarkdownBlockParser.parse(markdown: "```swift\ncode()\n```\n")
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .codeBlock(language: "swift"))
    }

    func testParseTable() {
        let doc = MarkdownBlockParser.parse(markdown: "| A | B |\n| --- | --- |\n| 1 | 2 |\n")
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .table)
        XCTAssertTrue(doc.blocks[0].rawText.contains("| --- |"))
    }

    func testParseTableSingleLine() {
        let doc = MarkdownBlockParser.parse(markdown: "| A | B |\n")
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .table)
    }

    func testParseParagraph() {
        let doc = MarkdownBlockParser.parse(markdown: "just text\n")
        XCTAssertEqual(doc.blocks[0].kind, .paragraph)
    }

    func testParseEmptyLine() {
        let doc = MarkdownBlockParser.parse(markdown: "\n")
        XCTAssertEqual(doc.blocks[0].kind, .empty)
    }

    // MARK: - Identity merge

    func testMergeIdentityPreservesUUIDs() {
        let old = MarkdownBlockParser.parse(markdown: "# Heading\n\nParagraph\n")
        let headingId = old.blocks[0].id
        let emptyId = old.blocks[1].id
        let paraId = old.blocks[2].id

        let new = MarkdownBlockParser.parse(markdown: "# Heading!\n\nParagraph\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)

        XCTAssertEqual(merged.blocks[0].id, headingId)
        XCTAssertEqual(merged.blocks[1].id, emptyId)
        XCTAssertEqual(merged.blocks[2].id, paraId)
    }

    func testMergeIdentityNewBlockGetsNewUUID() {
        let old = MarkdownBlockParser.parse(markdown: "# Heading\nParagraph\n")
        let headingId = old.blocks[0].id
        let paraId = old.blocks[1].id

        let new = MarkdownBlockParser.parse(markdown: "# Heading\n\nNew paragraph\nParagraph\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)

        XCTAssertEqual(merged.blocks.count, 4)
        XCTAssertEqual(merged.blocks[0].id, headingId)
        XCTAssertNotEqual(merged.blocks[1].id, headingId)
        XCTAssertNotEqual(merged.blocks[2].id, paraId)
        XCTAssertEqual(merged.blocks[3].id, paraId)
    }

    func testMergeIdentityDeletedBlockDropsUUID() {
        let old = MarkdownBlockParser.parse(markdown: "# Heading\n\nParagraph\n")
        let headingId = old.blocks[0].id
        let paraId = old.blocks[2].id

        let new = MarkdownBlockParser.parse(markdown: "# Heading\nParagraph\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)

        XCTAssertEqual(merged.blocks.count, 2)
        XCTAssertEqual(merged.blocks[0].id, headingId)
        XCTAssertEqual(merged.blocks[1].id, paraId)
    }

    func testMergeIdentityKindChangeLosesUUID() {
        let old = MarkdownBlockParser.parse(markdown: "Paragraph\n")
        let oldId = old.blocks[0].id

        let new = MarkdownBlockParser.parse(markdown: "# Heading\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)

        XCTAssertNotEqual(merged.blocks[0].id, oldId)
    }

    func testMergeIdentityFromEmptyDocument() {
        let old = BlockDocument(blocks: [], source: "")
        let new = MarkdownBlockParser.parse(markdown: "# Hello\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)

        XCTAssertEqual(merged.blocks.count, 1)
        XCTAssertEqual(merged.blocks[0].kind, .heading(level: 1))
    }

    // MARK: - Content-Aware Identity Merge

    func testMergeIdentityPreservesUUIDOnReorder() {
        let old = MarkdownBlockParser.parse(markdown: "First para\nSecond para\n")
        let firstId = old.blocks[0].id
        let secondId = old.blocks[1].id

        let new = MarkdownBlockParser.parse(markdown: "Second para\nFirst para\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)

        XCTAssertEqual(merged.blocks[0].id, secondId)
        XCTAssertEqual(merged.blocks[1].id, firstId)
    }

    func testMergeIdentityMinorEditPreservesUUID() {
        let old = MarkdownBlockParser.parse(markdown: "Hello world paragraph\n")
        let oldId = old.blocks[0].id

        let new = MarkdownBlockParser.parse(markdown: "Hello world paragraph!\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)

        XCTAssertEqual(merged.blocks[0].id, oldId)
    }

    func testMergeIdentityDoesNotLeakDeletedUUID() {
        let old = MarkdownBlockParser.parse(markdown: "Old A\nOld B\nOld C\n")
        let oldAId = old.blocks[0].id
        let oldBId = old.blocks[1].id
        let oldCId = old.blocks[2].id

        let new = MarkdownBlockParser.parse(markdown: "Old B\nInserted X\nOld C\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)

        XCTAssertEqual(merged.blocks[0].id, oldBId)
        XCTAssertNotEqual(merged.blocks[1].id, oldAId)
        XCTAssertNotEqual(merged.blocks[1].id, oldBId)
        XCTAssertNotEqual(merged.blocks[1].id, oldCId)
        XCTAssertEqual(merged.blocks[2].id, oldCId)
    }

    func testMergeIdentityDifferentKindGetsNewUUID() {
        let old = MarkdownBlockParser.parse(markdown: "Plain paragraph\n")
        let oldId = old.blocks[0].id

        let new = MarkdownBlockParser.parse(markdown: "# Now a heading\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)

        XCTAssertNotEqual(merged.blocks[0].id, oldId)
    }

    func testMergeIdentityPositionalBias() {
        let old = MarkdownBlockParser.parse(markdown: "\n\n\n")
        let count = old.blocks.count
        XCTAssertGreaterThan(count, 0, "Expected at least 1 block from '\\n\\n\\n', got \(count)")

        let new = MarkdownBlockParser.parse(markdown: "\n\n\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)

        XCTAssertEqual(merged.blocks.count, count)
        for i in 0..<min(count, merged.blocks.count) {
            XCTAssertEqual(merged.blocks[i].id, old.blocks[i].id)
        }
    }

    // MARK: - Table parse

    func testTableFollowedByParagraph() {
        let md = "| A |\n| --- |\nParagraph\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(doc.blocks[0].kind, .table)
        XCTAssertEqual(doc.blocks[1].kind, .paragraph)
    }

    // MARK: - EditorBlock Content Helpers

    func testBlockContentExtraction() {
        let doc = MarkdownBlockParser.parse(markdown: "# Hello World\n")
        XCTAssertEqual(doc.blocks[0].content, "Hello World")
    }

    func testBlockContentParagraph() {
        let doc = MarkdownBlockParser.parse(markdown: "Some text\n")
        XCTAssertEqual(doc.blocks[0].content, "Some text")
    }

    func testBlockContentBullet() {
        let doc = MarkdownBlockParser.parse(markdown: "- item text\n")
        XCTAssertEqual(doc.blocks[0].content, "item text")
    }

    func testBlockContentCheckbox() {
        let doc = MarkdownBlockParser.parse(markdown: "- [x] done\n")
        XCTAssertEqual(doc.blocks[0].content, "done")
    }

    func testBlockContentOrdered() {
        let doc = MarkdownBlockParser.parse(markdown: "1. first\n")
        XCTAssertEqual(doc.blocks[0].content, "first")
    }

    func testBlockContentBlockquote() {
        let doc = MarkdownBlockParser.parse(markdown: "> quoted\n")
        XCTAssertEqual(doc.blocks[0].content, "quoted")
    }

    func testBlockContentEmpty() {
        let doc = MarkdownBlockParser.parse(markdown: "\n")
        XCTAssertEqual(doc.blocks[0].content, "")
    }

    func testWithContentPreservesKindAndPrefix() {
        let doc = MarkdownBlockParser.parse(markdown: "## Hello\n")
        let block = doc.blocks[0]
        let updated = block.withContent("Goodbye")
        XCTAssertEqual(updated.rawText, "## Goodbye\n")
        XCTAssertEqual(updated.kind, .heading(level: 2))
        XCTAssertEqual(updated.prefix, block.prefix)
    }

    func testWithContentBullet() {
        let doc = MarkdownBlockParser.parse(markdown: "- old\n")
        let updated = doc.blocks[0].withContent("new")
        XCTAssertEqual(updated.rawText, "- new\n")
    }

    func testWithContentCheckbox() {
        let doc = MarkdownBlockParser.parse(markdown: "- [x] old\n")
        let updated = doc.blocks[0].withContent("new")
        XCTAssertEqual(updated.rawText, "- [x] new\n")
    }

    func testWithCheckedStateToggle() {
        let doc = MarkdownBlockParser.parse(markdown: "- [ ] todo\n")
        let checked = doc.blocks[0].withCheckedState(true)
        XCTAssertEqual(checked.rawText, "- [x] todo\n")
        if case .checkboxItem(let c, _) = checked.kind {
            XCTAssertTrue(c)
        } else {
            XCTFail("Expected checkboxItem")
        }

        let unchecked = checked.withCheckedState(false)
        XCTAssertEqual(unchecked.rawText, "- [ ] todo\n")
    }

    func testWithContentRoundTrip() {
        let markdown = "## Hello\n- item\n> quote\n1. first\n- [x] done\n"
        let doc = MarkdownBlockParser.parse(markdown: markdown)
        var rebuilt = doc
        for i in 0..<rebuilt.blocks.count {
            let content = rebuilt.blocks[i].content
            rebuilt.blocks[i] = rebuilt.blocks[i].withContent(content)
        }
        let serialized = rebuilt.blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, markdown)
    }

    /// Hot-path splicer coverage: every other withContent test passes `spans: []`,
    /// so the `InlineSerializer.serialize` branch of `rebuild` — the per-keystroke
    /// model→string step — was never exercised with real inline spans. This locks
    /// that non-empty spans survive the splice and the rawText round-trips back.
    func testWithContentPreservesNonEmptySpans() {
        let (clean, spans) = InlineParser.parse("plain **bold** and *italic* tail")
        XCTAssertFalse(spans.isEmpty, "fixture must carry inline spans")

        let block = MarkdownBlockParser.parse(markdown: "seed\n").blocks[0].withContent(clean, spans: spans)
        XCTAssertEqual(block.content, clean, "content getter returns clean text without markers")
        XCTAssertEqual(block.spans.map(\.styles), spans.map(\.styles), "inline spans survive the hot-path splicer")

        let (reparsedClean, reparsedSpans) = InlineParser.parse(block.rawText.trimmingCharacters(in: .newlines))
        XCTAssertEqual(reparsedClean, clean, "rawText reserializes spans and round-trips to the same clean text")
        XCTAssertEqual(reparsedSpans.map(\.styles), spans.map(\.styles), "reserialized markdown re-parses to equivalent spans")
    }

    // MARK: - withKind

    func testWithKindParagraphToHeading() {
        let doc = MarkdownBlockParser.parse(markdown: "Some text\n")
        let converted = doc.blocks[0].withKind(.heading(level: 2))
        XCTAssertEqual(converted.rawText, "## Some text\n")
        XCTAssertEqual(converted.kind, .heading(level: 2))
        XCTAssertEqual(converted.content, "Some text")
    }

    func testWithKindHeadingToBullet() {
        let doc = MarkdownBlockParser.parse(markdown: "## Title\n")
        let converted = doc.blocks[0].withKind(.bulletItem(marker: "-"))
        XCTAssertEqual(converted.rawText, "- Title\n")
        XCTAssertEqual(converted.kind, .bulletItem(marker: "-"))
    }

    func testWithKindBulletToCheckbox() {
        let doc = MarkdownBlockParser.parse(markdown: "- item\n")
        let converted = doc.blocks[0].withKind(.checkboxItem(checked: false, marker: "-"))
        XCTAssertEqual(converted.rawText, "- [ ] item\n")
    }

    func testWithKindToBlockquote() {
        let doc = MarkdownBlockParser.parse(markdown: "Some text\n")
        let converted = doc.blocks[0].withKind(.blockquote)
        XCTAssertEqual(converted.rawText, "> Some text\n")
    }

    func testWithKindToParagraph() {
        let doc = MarkdownBlockParser.parse(markdown: "## Heading\n")
        let converted = doc.blocks[0].withKind(.paragraph)
        XCTAssertEqual(converted.rawText, "Heading\n")
        XCTAssertEqual(converted.kind, .paragraph)
    }

    func testWithKindUnsupportedReturnsUnchanged() {
        let doc = MarkdownBlockParser.parse(markdown: "text\n")
        let original = doc.blocks[0]
        let toCode = original.withKind(.codeBlock(language: "swift"))
        XCTAssertEqual(toCode.id, original.id)
        XCTAssertEqual(toCode.kind, .paragraph)
        XCTAssertEqual(toCode.rawText, original.rawText)

        let toHR = original.withKind(.horizontalRule)
        XCTAssertEqual(toHR.kind, .paragraph)
        XCTAssertEqual(toHR.rawText, original.rawText)

        let toTable = original.withKind(.table)
        XCTAssertEqual(toTable.kind, .paragraph)

        let toImage = original.withKind(.image(alt: "", url: ""))
        XCTAssertEqual(toImage.kind, .paragraph)
    }

    func testWithKindPreservesId() {
        let doc = MarkdownBlockParser.parse(markdown: "text\n")
        let original = doc.blocks[0]
        let converted = original.withKind(.heading(level: 1))
        XCTAssertEqual(converted.id, original.id)
    }

    // MARK: - withIndent

    func testWithIndentAddsIndent() {
        let doc = MarkdownBlockParser.parse(markdown: "- item\n")
        let indented = doc.blocks[0].withIndent("  ")
        XCTAssertEqual(indented.rawText, "  - item\n")
        XCTAssertEqual(indented.indent, "  ")
        XCTAssertEqual(indented.content, "item")
    }

    func testWithIndentRemovesIndent() {
        let doc = MarkdownBlockParser.parse(markdown: "  - item\n")
        let outdented = doc.blocks[0].withIndent("")
        XCTAssertEqual(outdented.rawText, "- item\n")
        XCTAssertEqual(outdented.indent, "")
    }

    func testWithIndentPreservesKindAndContent() {
        let doc = MarkdownBlockParser.parse(markdown: "- [x] done\n")
        let indented = doc.blocks[0].withIndent("    ")
        XCTAssertEqual(indented.rawText, "    - [x] done\n")
        XCTAssertEqual(indented.content, "done")
        if case .checkboxItem(let checked, _) = indented.kind {
            XCTAssertTrue(checked)
        } else {
            XCTFail("Expected checkboxItem")
        }
    }

    // MARK: - Renumber

    func testRenumberOrderedRunsAfterDirectMutation() {
        var blocks = MarkdownBlockParser.parse(markdown: "1. One\n2. Two\n3. Three\n").blocks
        let removed = blocks.remove(at: 1)
        _ = removed
        MarkdownBlockParser.renumberOrderedRuns(&blocks)
        let serialized = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, "1. One\n2. Three\n")
    }

    func testRenumberOrderedRunsAfterDuplicate() {
        var blocks = MarkdownBlockParser.parse(markdown: "1. One\n2. Two\n").blocks
        var copy = blocks[0]
        copy.id = UUID()
        blocks.insert(copy, at: 1)
        MarkdownBlockParser.renumberOrderedRuns(&blocks)
        let serialized = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, "1. One\n2. One\n3. Two\n")
    }

    func testRenumberOrderedRunsUpdatesPrefixForWithContent() {
        var blocks = MarkdownBlockParser.parse(markdown: "1. Alpha\n2. Beta\n").blocks
        blocks.swapAt(0, 1)
        MarkdownBlockParser.renumberOrderedRuns(&blocks)
        XCTAssertEqual(blocks[0].prefix, "1. ")
        XCTAssertEqual(blocks[1].prefix, "2. ")

        let edited = blocks[0].withContent("Edited")
        XCTAssertEqual(edited.rawText, "1. Edited\n")
        let edited2 = blocks[1].withContent("Also edited")
        XCTAssertEqual(edited2.rawText, "2. Also edited\n")
    }

    func testRenumberOrderedRunsAfterSwap() {
        var blocks = MarkdownBlockParser.parse(markdown: "1. Alpha\n2. Beta\n3. Gamma\n").blocks
        blocks.swapAt(0, 2)
        MarkdownBlockParser.renumberOrderedRuns(&blocks)
        let serialized = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, "1. Gamma\n2. Beta\n3. Alpha\n")
    }

    // MARK: - Code Block Content

    func testCodeContentExtraction() {
        let doc = MarkdownBlockParser.parse(markdown: "```swift\nlet x = 1\nlet y = 2\n```\n")
        XCTAssertEqual(doc.blocks[0].codeContent, "let x = 1\nlet y = 2")
    }

    func testCodeContentEmptyBody() {
        let doc = MarkdownBlockParser.parse(markdown: "```\n```\n")
        XCTAssertEqual(doc.blocks[0].codeContent, "")
    }

    func testCodeContentNoLanguage() {
        let doc = MarkdownBlockParser.parse(markdown: "```\nhello\n```\n")
        XCTAssertEqual(doc.blocks[0].codeContent, "hello")
        XCTAssertNil(doc.blocks[0].codeLanguage)
    }

    func testCodeLanguageExtraction() {
        let doc = MarkdownBlockParser.parse(markdown: "```python\nprint('hi')\n```\n")
        XCTAssertEqual(doc.blocks[0].codeLanguage, "python")
    }

    func testCodeContentNonCodeReturnsNil() {
        let doc = MarkdownBlockParser.parse(markdown: "paragraph\n")
        XCTAssertNil(doc.blocks[0].codeContent)
    }

    func testWithCodeContentRoundTrip() {
        let md = "```swift\nlet x = 1\n```\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        let block = doc.blocks[0]
        let updated = block.withCodeContent(block.codeContent!)
        XCTAssertEqual(updated.rawText, md)
    }

    func testWithCodeContentReplace() {
        let doc = MarkdownBlockParser.parse(markdown: "```js\nold()\n```\n")
        let updated = doc.blocks[0].withCodeContent("newCode()")
        XCTAssertEqual(updated.rawText, "```js\nnewCode()\n```\n")
    }

    func testWithCodeContentPreservesLanguage() {
        let doc = MarkdownBlockParser.parse(markdown: "```rust\nfn main() {}\n```\n")
        let updated = doc.blocks[0].withCodeContent("fn other() {}")
        XCTAssertEqual(updated.rawText, "```rust\nfn other() {}\n```\n")
        XCTAssertEqual(updated.codeLanguage, "rust")
    }

    func testWithCodeContentOnNonCodeReturnsUnchanged() {
        let doc = MarkdownBlockParser.parse(markdown: "paragraph\n")
        let original = doc.blocks[0]
        let result = original.withCodeContent("anything")
        XCTAssertEqual(result.rawText, original.rawText)
    }

    // MARK: - Document-Level Block Operations

    func testSplitBulletContinuationViaBlocks() {
        var blocks = MarkdownBlockParser.parse(markdown: "- first\n- second\n").blocks
        let newBlock = blocks[1].continuationBlock(content: "inserted")
        blocks.insert(newBlock, at: 2)
        let serialized = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, "- first\n- second\n- inserted\n")
    }

    func testEmptyBulletExitToParagraphViaBlocks() {
        var blocks = MarkdownBlockParser.parse(markdown: "- item\n- \n").blocks
        XCTAssertEqual(blocks.count, 2)
        blocks[1] = EditorBlock.paragraph(content: "")
        let serialized = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, "- item\n\n")
    }

    func testMergeBlocksPreservesContent() {
        var blocks = MarkdownBlockParser.parse(markdown: "Hello \nWorld\n").blocks
        XCTAssertEqual(blocks.count, 2)
        let merged = blocks[0].content + blocks[1].content
        blocks[0] = blocks[0].withContent(merged)
        blocks.remove(at: 1)
        let serialized = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, "Hello World\n")
    }

    func testConvertAndSerializeViaBlocks() {
        var blocks = MarkdownBlockParser.parse(markdown: "plain text\n").blocks
        blocks[0] = blocks[0].withKind(.heading(level: 2))
        let serialized = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, "## plain text\n")

        blocks[0] = blocks[0].withKind(.bulletItem(marker: "-"))
        let serialized2 = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized2, "- plain text\n")
    }

    func testIndentOutdentRoundTripViaBlocks() {
        var blocks = MarkdownBlockParser.parse(markdown: "- item\n").blocks
        blocks[0] = blocks[0].withIndent("  ")
        XCTAssertEqual(blocks.map(\.rawText).joined(), "  - item\n")

        blocks[0] = blocks[0].withIndent("")
        XCTAssertEqual(blocks.map(\.rawText).joined(), "- item\n")
    }

    func testDuplicateViaBlocks() {
        var blocks = MarkdownBlockParser.parse(markdown: "## Title\nParagraph\n").blocks
        var copy = blocks[0]
        copy.id = UUID()
        blocks.insert(copy, at: 1)
        let serialized = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, "## Title\n## Title\nParagraph\n")
        XCTAssertNotEqual(blocks[0].id, blocks[1].id)
    }

    func testMoveBlockViaBlocks() {
        var blocks = MarkdownBlockParser.parse(markdown: "# First\nSecond\nThird\n").blocks
        let moved = blocks.remove(at: 2)
        blocks.insert(moved, at: 0)
        let serialized = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, "Third\n# First\nSecond\n")
    }

    func testDeleteOnlyBlockReplacesWithEmpty() {
        var blocks = MarkdownBlockParser.parse(markdown: "only\n").blocks
        XCTAssertEqual(blocks.count, 1)
        blocks[0] = EditorBlock.empty()
        let serialized = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, "\n")
    }

    func testCodeBlockEditThroughWithCodeContent() {
        var blocks = MarkdownBlockParser.parse(markdown: "before\n```swift\ncode()\n```\nafter\n").blocks
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1].codeContent, "code()")
        blocks[1] = blocks[1].withCodeContent("newCode()\nmoreLine()")
        let serialized = blocks.map(\.rawText).joined()
        XCTAssertEqual(serialized, "before\n```swift\nnewCode()\nmoreLine()\n```\nafter\n")
    }

    // MARK: - Image Parsing

    func testParseImage() {
        let doc = MarkdownBlockParser.parse(markdown: "![alt text](image.png)\n")
        XCTAssertEqual(doc.blocks.count, 1)
        if case .image(let alt, let url) = doc.blocks[0].kind {
            XCTAssertEqual(alt, "alt text")
            XCTAssertEqual(url, "image.png")
        } else {
            XCTFail("Expected .image kind, got \(doc.blocks[0].kind)")
        }
    }

    func testParseImageWithPath() {
        let doc = MarkdownBlockParser.parse(markdown: "![screenshot](Attachments/block/img.jpg)\n")
        if case .image(let alt, let url) = doc.blocks[0].kind {
            XCTAssertEqual(alt, "screenshot")
            XCTAssertEqual(url, "Attachments/block/img.jpg")
        } else {
            XCTFail("Expected .image kind")
        }
    }

    func testParseImageEmptyAlt() {
        let doc = MarkdownBlockParser.parse(markdown: "![](photo.png)\n")
        if case .image(let alt, let url) = doc.blocks[0].kind {
            XCTAssertEqual(alt, "")
            XCTAssertEqual(url, "photo.png")
        } else {
            XCTFail("Expected .image kind")
        }
    }

    func testMergeIdentityImageAltEditGetsNewUUID() {
        let old = MarkdownBlockParser.parse(markdown: "![screenshot of dashboard](img.png)\n")
        let oldId = old.blocks[0].id

        let new = MarkdownBlockParser.parse(markdown: "![screenshot of settings](img.png)\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)

        XCTAssertNotEqual(merged.blocks[0].id, oldId)
    }

    func testParseImageAmongBlocks() {
        let md = "# Title\n![pic](a.png)\nParagraph\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        XCTAssertEqual(doc.blocks.count, 3)
        XCTAssertEqual(doc.blocks[0].kind, .heading(level: 1))
        if case .image = doc.blocks[1].kind {} else {
            XCTFail("Expected .image kind at index 1")
        }
        XCTAssertEqual(doc.blocks[2].kind, .paragraph)
    }

    // MARK: - Continuation Blocks

    func testContinuationBlockBullet() {
        let doc = MarkdownBlockParser.parse(markdown: "- item\n")
        let next = doc.blocks[0].continuationBlock(content: "new")
        XCTAssertEqual(next.rawText, "- new\n")
        XCTAssertEqual(next.kind, .bulletItem(marker: "-"))
        XCTAssertNotEqual(next.id, doc.blocks[0].id)
    }

    func testContinuationBlockOrdered() {
        let doc = MarkdownBlockParser.parse(markdown: "3. third\n")
        let next = doc.blocks[0].continuationBlock(content: "fourth")
        XCTAssertEqual(next.rawText, "4. fourth\n")
    }

    func testContinuationBlockCheckbox() {
        let doc = MarkdownBlockParser.parse(markdown: "- [x] done\n")
        let next = doc.blocks[0].continuationBlock(content: "todo")
        XCTAssertEqual(next.rawText, "- [ ] todo\n")
    }

    func testContinuationBlockParagraph() {
        let doc = MarkdownBlockParser.parse(markdown: "text\n")
        let next = doc.blocks[0].continuationBlock(content: "more")
        XCTAssertEqual(next.kind, .paragraph)
        XCTAssertEqual(next.rawText, "more\n")
    }

    func testContinuationBlockHeading() {
        let doc = MarkdownBlockParser.parse(markdown: "## heading\n")
        let next = doc.blocks[0].continuationBlock(content: "text")
        XCTAssertEqual(next.kind, .paragraph)
    }

    func testExitsOnEmptyEnter() {
        XCTAssertTrue(MarkdownBlockParser.parse(markdown: "- item\n").blocks[0].exitsOnEmptyEnter)
        XCTAssertTrue(MarkdownBlockParser.parse(markdown: "1. item\n").blocks[0].exitsOnEmptyEnter)
        XCTAssertTrue(MarkdownBlockParser.parse(markdown: "- [ ] item\n").blocks[0].exitsOnEmptyEnter)
        XCTAssertTrue(MarkdownBlockParser.parse(markdown: "> quote\n").blocks[0].exitsOnEmptyEnter)
        XCTAssertFalse(MarkdownBlockParser.parse(markdown: "text\n").blocks[0].exitsOnEmptyEnter)
        XCTAssertFalse(MarkdownBlockParser.parse(markdown: "## heading\n").blocks[0].exitsOnEmptyEnter)
    }

    func testDividerFactory() {
        let block = EditorBlock.divider()
        XCTAssertEqual(block.kind, .horizontalRule)
        XCTAssertEqual(block.rawText, "---\n")
    }

    func testParagraphFactory() {
        let block = EditorBlock.paragraph(content: "hello")
        XCTAssertEqual(block.kind, .paragraph)
        XCTAssertEqual(block.rawText, "hello\n")
        XCTAssertEqual(block.content, "hello")
    }

    func testEmptyFactory() {
        let block = EditorBlock.empty()
        XCTAssertEqual(block.kind, .empty)
        XCTAssertEqual(block.rawText, "\n")
        XCTAssertEqual(block.content, "")
    }

    // MARK: - Phase 1: Block Tree Structure

    func testParseComputesDepth() {
        let md = "- root\n  - child\n    - grandchild\n- root2\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        XCTAssertEqual(doc.blocks.count, 4)
        XCTAssertEqual(doc.blocks[0].depth, 0)
        XCTAssertEqual(doc.blocks[1].depth, 1)
        XCTAssertEqual(doc.blocks[2].depth, 2)
        XCTAssertEqual(doc.blocks[3].depth, 0)
    }

    func testDepthFromIndent() {
        XCTAssertEqual(BlockTreeNavigator.depthFromIndent(""), 0)
        XCTAssertEqual(BlockTreeNavigator.depthFromIndent("  "), 1)
        XCTAssertEqual(BlockTreeNavigator.depthFromIndent("    "), 2)
        XCTAssertEqual(BlockTreeNavigator.depthFromIndent("\t"), 1)
        XCTAssertEqual(BlockTreeNavigator.depthFromIndent("\t\t"), 2)
        XCTAssertEqual(BlockTreeNavigator.depthFromIndent("  \t"), 2)
    }

    func testChildrenOfIndex() {
        let md = "- parent\n  - child1\n  - child2\n- sibling\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        let subtree = BlockTreeNavigator.subtreeRange(of: 0, in: doc.blocks)
        XCTAssertEqual(subtree, 0..<3)
    }

    func testSubtreeRange() {
        let md = "- parent\n  - child1\n    - grandchild\n  - child2\n- other\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        let range = BlockTreeNavigator.subtreeRange(of: 0, in: doc.blocks)
        XCTAssertEqual(range, 0..<4)
    }

    func testParentOfIndex() {
        let md = "- parent\n  - child\n    - grandchild\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        XCTAssertNil(BlockTreeNavigator.parent(of: 0, in: doc.blocks))
        XCTAssertEqual(BlockTreeNavigator.parent(of: 1, in: doc.blocks), 0)
        XCTAssertEqual(BlockTreeNavigator.parent(of: 2, in: doc.blocks), 1)
    }

    func testVisibleBlocksWithCollapse() {
        let md = "- parent\n  - child1\n  - child2\n- other\n"
        var doc = MarkdownBlockParser.parse(markdown: md)
        doc.blocks[0].collapsed = true
        let visible = BlockTreeNavigator.visibleBlocks(doc.blocks)
        XCTAssertEqual(visible, [0, 3])
    }

    func testVisibleBlocksNoCollapse() {
        let md = "- a\n  - b\n- c\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        let visible = BlockTreeNavigator.visibleBlocks(doc.blocks)
        XCTAssertEqual(visible, [0, 1, 2])
    }

    func testHasChildren() {
        let md = "- parent\n  - child\n- leaf\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        XCTAssertTrue(BlockTreeNavigator.hasChildren(0, in: doc.blocks))
        XCTAssertFalse(BlockTreeNavigator.hasChildren(1, in: doc.blocks))
        XCTAssertFalse(BlockTreeNavigator.hasChildren(2, in: doc.blocks))
    }

    func testSiblings() {
        let md = "- a\n  - b\n  - c\n- d\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        let rootSiblings = BlockTreeNavigator.siblings(of: 0, in: doc.blocks)
        XCTAssertEqual(rootSiblings, [0, 3])
        let childSiblings = BlockTreeNavigator.siblings(of: 1, in: doc.blocks)
        XCTAssertEqual(childSiblings, [1, 2])
    }

    func testIndentMakesChildOfPreviousSibling() {
        let md = "- first\n- second\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        let indented = doc.blocks[1].withIndent("  ")
        XCTAssertEqual(indented.depth, 1)
        XCTAssertEqual(indented.rawText, "  - second\n")
    }

    func testOutdentReducesDepth() {
        let md = "- parent\n  - child\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        let outdented = doc.blocks[1].withIndent("")
        XCTAssertEqual(outdented.depth, 0)
        XCTAssertEqual(outdented.rawText, "- child\n")
    }

    func testMoveSubtree() {
        let md = "- a\n  - a1\n- b\n"
        var blocks = MarkdownBlockParser.parse(markdown: md).blocks
        let subtree = BlockTreeNavigator.subtreeRange(of: 0, in: blocks)
        XCTAssertEqual(subtree, 0..<2)
        let slice = Array(blocks[subtree])
        blocks.removeSubrange(subtree)
        blocks.append(contentsOf: slice)
        XCTAssertEqual(blocks.map(\.rawText).joined(), "- b\n- a\n  - a1\n")
    }

    func testDeleteSubtree() {
        let md = "- parent\n  - child1\n  - child2\n- other\n"
        var blocks = MarkdownBlockParser.parse(markdown: md).blocks
        let subtree = BlockTreeNavigator.subtreeRange(of: 0, in: blocks)
        blocks.removeSubrange(subtree)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].rawText, "- other\n")
    }

    func testDepthClampingOnParse() {
        let md = "- root\n      - skipped\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        XCTAssertEqual(doc.blocks[0].depth, 0)
        XCTAssertEqual(doc.blocks[1].depth, 1)
    }

    func testNonListBlocksAlwaysDepthZero() {
        let md = "# Heading\nParagraph\n---\n\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        for block in doc.blocks {
            XCTAssertEqual(block.depth, 0, "Block kind \(block.kind) should have depth 0")
        }
    }

    func testBlockquoteDepthFromMarkers() {
        let md = "> level 1\n> > level 2\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        XCTAssertEqual(doc.blocks[0].depth, 0)
        XCTAssertEqual(doc.blocks[1].depth, 1)
    }

    func testWithKindResetsDepthForNonList() {
        let md = "  - item\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        XCTAssertEqual(doc.blocks[0].depth, 1)
        let converted = doc.blocks[0].withKind(.paragraph)
        XCTAssertEqual(converted.depth, 0)
    }

    func testMergeIdentityPreservesCollapsed() {
        var old = MarkdownBlockParser.parse(markdown: "- parent\n  - child\n")
        old.blocks[0].collapsed = true
        let new = MarkdownBlockParser.parse(markdown: "- parent\n  - child\n")
        let merged = MarkdownBlockParser.mergeIdentity(old: old, new: new)
        XCTAssertTrue(merged.blocks[0].collapsed)
    }

    func testContinuationBlockInheritsDepth() {
        let md = "  - item\n"
        let doc = MarkdownBlockParser.parse(markdown: md)
        let next = doc.blocks[0].continuationBlock(content: "new")
        XCTAssertEqual(next.depth, 1)
        XCTAssertEqual(next.rawText, "  - new\n")
    }

    func testFactoryBlocksHaveDepthZero() {
        XCTAssertEqual(EditorBlock.paragraph(content: "hi").depth, 0)
        XCTAssertEqual(EditorBlock.empty().depth, 0)
        XCTAssertEqual(EditorBlock.divider().depth, 0)
        XCTAssertFalse(EditorBlock.paragraph(content: "hi").collapsed)
    }

    func testOutdentReparentsFollowingSiblings() {
        let md = "- parent\n  - a\n  - b\n  - c\n"
        var blocks = MarkdownBlockParser.parse(markdown: md).blocks
        XCTAssertEqual(blocks[1].depth, 1)
        XCTAssertEqual(blocks[2].depth, 1)
        XCTAssertEqual(blocks[3].depth, 1)
        let subtree = BlockTreeNavigator.subtreeRange(of: 1, in: blocks)
        let parentSubtree = BlockTreeNavigator.subtreeRange(of: 0, in: blocks)
        let followStart = subtree.upperBound
        let followEnd = parentSubtree.upperBound
        XCTAssertEqual(subtree, 1..<2)
        for i in subtree {
            blocks[i] = blocks[i].withIndent("")
        }
        if followStart < followEnd {
            for i in followStart..<followEnd {
                blocks[i] = blocks[i].withIndent(blocks[i].indent + "  ")
            }
        }
        XCTAssertEqual(blocks[1].depth, 0)
        XCTAssertEqual(blocks[2].depth, 2)
        XCTAssertEqual(blocks[3].depth, 2)
    }

    // MARK: - SpanStyler

    func testSpanStylerAppliesBold() {
        let ts = NSTextStorage(string: "hello bold world")
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ts.setAttributes([.font: baseFont], range: NSRange(location: 0, length: ts.length))
        let spans = [InlineSpan(range: NSRange(location: 6, length: 4), styles: [.bold])]
        SpanStyler.apply(spans: spans, to: ts, baseFont: baseFont)
        let font = ts.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.fontName, SpanStyler.boldFont(for: baseFont).fontName)
        let normalFont = ts.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(normalFont?.fontName, baseFont.fontName)
    }

    func testSpanStylerAppliesItalic() {
        let ts = NSTextStorage(string: "hello italic world")
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ts.setAttributes([.font: baseFont], range: NSRange(location: 0, length: ts.length))
        let spans = [InlineSpan(range: NSRange(location: 6, length: 6), styles: [.italic])]
        SpanStyler.apply(spans: spans, to: ts, baseFont: baseFont)
        let font = ts.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        let matrix = CTFontGetMatrix(font! as CTFont)
        XCTAssertNotEqual(matrix.c, 0)
    }

    func testSpanStylerAppliesStrikethrough() {
        let ts = NSTextStorage(string: "hello struck world")
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ts.setAttributes([.font: baseFont], range: NSRange(location: 0, length: ts.length))
        let spans = [InlineSpan(range: NSRange(location: 6, length: 6), styles: [.strikethrough])]
        SpanStyler.apply(spans: spans, to: ts, baseFont: baseFont)
        let strike = ts.attribute(.strikethroughStyle, at: 6, effectiveRange: nil) as? Int
        XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue)
    }

    func testSpanStylerAppliesCode() {
        let ts = NSTextStorage(string: "run code here")
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ts.setAttributes([.font: baseFont], range: NSRange(location: 0, length: ts.length))
        let spans = [InlineSpan(range: NSRange(location: 4, length: 4), styles: [.code])]
        SpanStyler.apply(spans: spans, to: ts, baseFont: baseFont)
        let font = ts.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.fontName, SpanStyler.codeFont(for: baseFont).fontName)
        let bg = ts.attribute(.backgroundColor, at: 4, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(bg)
    }

    func testSpanStylerAppliesBoldItalic() {
        let ts = NSTextStorage(string: "both")
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ts.setAttributes([.font: baseFont], range: NSRange(location: 0, length: ts.length))
        let spans = [
            InlineSpan(range: NSRange(location: 0, length: 4), styles: [.bold, .italic])
        ]
        SpanStyler.apply(spans: spans, to: ts, baseFont: baseFont)
        let font = ts.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.fontName, SpanStyler.boldItalicFont(for: baseFont).fontName)
    }

    func testSpanStylerClampsOutOfBoundsRange() {
        let ts = NSTextStorage(string: "short")
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ts.setAttributes([.font: baseFont], range: NSRange(location: 0, length: ts.length))
        let spans = [InlineSpan(range: NSRange(location: 3, length: 100), styles: [.bold])]
        SpanStyler.apply(spans: spans, to: ts, baseFont: baseFont)
        let font = ts.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.fontName, SpanStyler.boldFont(for: baseFont).fontName)
    }

    // MARK: - SpanExtractor

    func testSpanExtractorExtractsBold() {
        let ts = NSTextStorage(string: "hello bold world")
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ts.setAttributes([.font: baseFont], range: NSRange(location: 0, length: ts.length))
        ts.addAttribute(.font, value: SpanStyler.boldFont(for: baseFont), range: NSRange(location: 6, length: 4))
        let spans = SpanExtractor.extract(from: ts, baseFont: baseFont)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].range, NSRange(location: 6, length: 4))
        XCTAssertEqual(spans[0].styles, [.bold])
    }

    func testSpanExtractorExtractsStrikethrough() {
        let ts = NSTextStorage(string: "hello struck world")
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ts.setAttributes([.font: baseFont], range: NSRange(location: 0, length: ts.length))
        ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 6, length: 6))
        let spans = SpanExtractor.extract(from: ts, baseFont: baseFont)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].styles, [.strikethrough])
    }

    func testSpanExtractorMergesAdjacentSameStyle() {
        let ts = NSTextStorage(string: "abcdef")
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ts.setAttributes([.font: baseFont], range: NSRange(location: 0, length: ts.length))
        ts.addAttribute(.font, value: SpanStyler.boldFont(for: baseFont), range: NSRange(location: 0, length: 3))
        ts.addAttribute(.font, value: SpanStyler.boldFont(for: baseFont), range: NSRange(location: 3, length: 3))
        let spans = SpanExtractor.extract(from: ts, baseFont: baseFont)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 6))
    }

    // MARK: - InlineSpan Split & Shift

    func testSpanSplitAtMiddle() {
        let spans = [InlineSpan(range: NSRange(location: 2, length: 6), styles: [.bold])]
        let (before, after) = InlineSpan.split(spans: spans, at: 5)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before[0].range, NSRange(location: 2, length: 3))
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].range, NSRange(location: 0, length: 3))
    }

    func testSpanSplitBeforeSpan() {
        let spans = [InlineSpan(range: NSRange(location: 5, length: 3), styles: [.italic])]
        let (before, after) = InlineSpan.split(spans: spans, at: 2)
        XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].range, NSRange(location: 3, length: 3))
    }

    func testSpanSplitAfterSpan() {
        let spans = [InlineSpan(range: NSRange(location: 0, length: 3), styles: [.bold])]
        let (before, after) = InlineSpan.split(spans: spans, at: 5)
        XCTAssertEqual(before.count, 1)
        XCTAssertTrue(after.isEmpty)
    }

    func testSpanShifted() {
        let spans = [InlineSpan(range: NSRange(location: 0, length: 3), styles: [.bold])]
        let shifted = InlineSpan.shifted(spans, by: 10)
        XCTAssertEqual(shifted[0].range, NSRange(location: 10, length: 3))
    }

    // MARK: - Phase 4: Floating Formatting Toolbar

    private func makeTextView(with text: String) -> BlockNSTextView {
        let ts = NSTextStorage(string: text)
        let lm = NSLayoutManager()
        ts.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        let tv = BlockNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100), textContainer: tc)
        tv.isEditable = true
        tv.isSelectable = true
        tv.baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.baseForeground = NSColor.labelColor
        return tv
    }

    func testToggleBoldAppliesAttribute() {
        let tv = makeTextView(with: "hello world")
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.toggleInlineFormat(style: .bold)
        XCTAssertEqual(tv.string, "hello world")
        let font = tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let boldFont = SpanStyler.boldFont(for: tv.baseFont)
        XCTAssertEqual(font?.fontName, boldFont.fontName)
    }

    func testToggleBoldRemovesAttribute() {
        let tv = makeTextView(with: "hello world")
        let ts = tv.textStorage!
        ts.addAttribute(.font, value: SpanStyler.boldFont(for: tv.baseFont), range: NSRange(location: 0, length: 5))
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.toggleInlineFormat(style: .bold)
        let font = ts.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.fontName, tv.baseFont.fontName)
    }

    func testToggleItalicAppliesAttribute() {
        let tv = makeTextView(with: "hello world")
        tv.setSelectedRange(NSRange(location: 6, length: 5))
        tv.toggleInlineFormat(style: .italic)
        XCTAssertEqual(tv.string, "hello world")
        let font = tv.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        let matrix = CTFontGetMatrix(font! as CTFont)
        XCTAssertNotEqual(matrix.c, 0)
    }

    func testToggleStrikethroughAppliesAttribute() {
        let tv = makeTextView(with: "hello world")
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.toggleInlineFormat(style: .strikethrough)
        XCTAssertEqual(tv.string, "hello world")
        let strike = tv.textStorage?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue)
    }

    func testToggleCodeAppliesAttribute() {
        let tv = makeTextView(with: "hello world")
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.toggleInlineFormat(style: .code)
        XCTAssertEqual(tv.string, "hello world")
        let font = tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let codeFont = SpanStyler.codeFont(for: tv.baseFont)
        XCTAssertEqual(font?.fontName, codeFont.fontName)
        XCTAssertEqual(font?.pointSize, codeFont.pointSize)
    }

    func testInsertLinkWrapsSelection() {
        let tv = makeTextView(with: "hello world")
        tv.setSelectedRange(NSRange(location: 6, length: 5))
        tv.insertLink()
        XCTAssertEqual(tv.string, "hello [world](url)")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 14, length: 3))
    }

    func testInsertLinkNoSelectionIsNoop() {
        let tv = makeTextView(with: "hello world")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertLink()
        XCTAssertEqual(tv.string, "hello world")
    }

    func testToolbarCreatedOnSelection() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let tv = makeTextView(with: "hello world")
        window.contentView?.addSubview(tv)
        tv.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        window.orderFront(nil)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)

        XCTAssertNil(tv.toolbarPanel)
        tv.setSelectedRange(NSRange(location: 0, length: 5), affinity: .downstream, stillSelecting: false)
        XCTAssertNotNil(tv.toolbarPanel)
        window.orderOut(nil)
    }

    func testToolbarNotCreatedDuringDrag() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let tv = makeTextView(with: "hello world")
        window.contentView?.addSubview(tv)
        tv.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        window.orderFront(nil)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)

        tv.setSelectedRange(NSRange(location: 0, length: 5), affinity: .downstream, stillSelecting: true)
        XCTAssertNil(tv.toolbarPanel)
        window.orderOut(nil)
    }

    func testConvertToEventCase() {
        var receivedKind: EditorBlockKind?
        let tv = makeTextView(with: "hello")
        tv.onEvent = { event in
            if case .convertTo(let kind) = event { receivedKind = kind }
        }
        tv.onEvent?(.convertTo(.heading(level: 2)))
        XCTAssertEqual(receivedKind, .heading(level: 2))
    }

    // MARK: - Phase 3: Unified Serialization Pipeline

    func testBlockEditorDocumentInitFromMarkdown() {
        let md = "# Hello\n\nParagraph\n"
        let doc = BlockEditorDocument(markdown: md)
        XCTAssertEqual(doc.blocks.count, 3)
        XCTAssertEqual(doc.blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(doc.serialize(), md)
    }

    func testBlockEditorDocumentLoadMarkdownMergesIdentity() {
        let doc = BlockEditorDocument(markdown: "# Title\nParagraph\n")
        let titleId = doc.blocks[0].id
        let paraId = doc.blocks[1].id

        doc.loadMarkdown("# Title\nParagraph!\n")

        XCTAssertEqual(doc.blocks[0].id, titleId)
        XCTAssertEqual(doc.blocks[1].id, paraId)
        XCTAssertEqual(doc.blocks[1].content, "Paragraph!")
    }

    func testBlockEditorDocumentUpdateBlockContent() {
        let doc = BlockEditorDocument(markdown: "# Title\nBody\n")
        let gen = doc.editGeneration
        let structGen = doc.structuralGeneration
        var dirtyCalled = false
        doc.onDirty = { dirtyCalled = true }

        doc.updateBlockContent(at: 1, content: "New body", spans: [])

        XCTAssertTrue(dirtyCalled)
        XCTAssertEqual(doc.blocks[1].content, "New body")
        XCTAssertEqual(doc.serialize(), "# Title\nNew body\n")
        XCTAssertEqual(doc.editGeneration, gen + 1, "content edits advance editGeneration so the store-sync gate stays closed while typing")
        XCTAssertEqual(doc.structuralGeneration, structGen, "content edits must NOT bump structuralGeneration — the visible-index cache stays put, no per-keystroke recompute")
    }

    func testBlockEditorDocumentStructuralEditIncrements() {
        let doc = BlockEditorDocument(markdown: "Line\n")
        let gen = doc.editGeneration
        let structGen = doc.structuralGeneration
        var dirtyCalled = false
        doc.onDirty = { dirtyCalled = true }

        doc.performStructuralEdit(undoManager: nil, name: "Test", newFocus: nil) { blocks in
            blocks.append(EditorBlock.paragraph(content: "new"))
        }

        XCTAssertTrue(dirtyCalled)
        XCTAssertEqual(doc.editGeneration, gen + 1)
        XCTAssertEqual(doc.structuralGeneration, structGen + 1, "structural edits bump structuralGeneration so the visible-index cache recomputes")
        XCTAssertEqual(doc.blocks.count, 2)
    }

    func testBlockEditorDocumentSerializeRoundTrip() {
        let md = "- bullet\n  - nested\n\n```swift\ncode()\n```\n"
        let doc = BlockEditorDocument(markdown: md)
        XCTAssertEqual(doc.serialize(), md)
    }

    func testBlockEditorDocumentHidesLegacySymphonyBodyMetadata() {
        let md = """
        ---
        symphony: true
        symphony_state: Human Review
        ---
        # SYM-001 Review the project

        [[Symphony]] #symphony

        State: Human Review

        ## Brief
        Keep this visible.
        """
        let doc = BlockEditorDocument(markdown: md)
        let serialized = doc.serialize()

        XCTAssertFalse(serialized.contains("[[Symphony]] #symphony"))
        XCTAssertFalse(serialized.contains("State: Human Review"))
        XCTAssertTrue(serialized.contains("symphony_state: Human Review"))
        XCTAssertTrue(serialized.contains("## Brief"))
        XCTAssertTrue(serialized.contains("Keep this visible."))
    }

    func testBlockEditorDocumentExternalChangeUpdatesContent() {
        let doc = BlockEditorDocument(markdown: "# Title\nOriginal paragraph\n")
        let titleId = doc.blocks[0].id

        doc.loadMarkdown("# Title\nUpdated paragraph\n")
        XCTAssertEqual(doc.blocks[0].id, titleId)
        XCTAssertEqual(doc.blocks[0].content, "Title")
        XCTAssertEqual(doc.blocks[1].content, "Updated paragraph")
        XCTAssertEqual(doc.serialize(), "# Title\nUpdated paragraph\n")
    }

    func testFocusRequestThreadSafety() {
        let iterations = 1000
        let group = DispatchGroup()
        var generations = Set<UInt64>()
        let lock = NSLock()

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let req = BlockFocusRequest(blockId: UUID(), cursorOffset: 0)
                lock.lock()
                generations.insert(req.generation)
                lock.unlock()
                group.leave()
            }
        }

        group.wait()
        XCTAssertEqual(generations.count, iterations)
    }

    func testUpdateBlockContentOutOfBoundsIsNoop() {
        let doc = BlockEditorDocument(markdown: "Only\n")
        doc.updateBlockContent(at: 5, content: "crash?", spans: [])
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].content, "Only")
    }

    func testUpdateCodeBlockContent() {
        let doc = BlockEditorDocument(markdown: "```swift\nold()\n```\n")
        doc.updateBlockContent(at: 0, content: "new()", spans: [])
        XCTAssertTrue(doc.serialize().contains("new()"))
        XCTAssertTrue(doc.serialize().contains("```swift"))
    }

    // MARK: - Phase 5: Virtualization

    func testStaticBlockCodeContent() {
        let doc = MarkdownBlockParser.parse(markdown: "```swift\nlet x = 1\n```\n")
        let block = doc.blocks[0]
        XCTAssertEqual(block.codeContent, "let x = 1")
    }

    // MARK: - InlineParser

    func testParseNoFormatting() {
        let (text, spans) = InlineParser.parse("no formatting")
        XCTAssertEqual(text, "no formatting")
        XCTAssertTrue(spans.isEmpty)
    }

    func testParseEmpty() {
        let (text, spans) = InlineParser.parse("")
        XCTAssertEqual(text, "")
        XCTAssertTrue(spans.isEmpty)
    }

    func testParseBold() {
        let (text, spans) = InlineParser.parse("Hello **bold** world")
        XCTAssertEqual(text, "Hello bold world")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].range, NSRange(location: 6, length: 4))
        XCTAssertEqual(spans[0].styles, [.bold])
    }

    func testParseItalic() {
        let (text, spans) = InlineParser.parse("Hello *italic* world")
        XCTAssertEqual(text, "Hello italic world")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].range, NSRange(location: 6, length: 6))
        XCTAssertEqual(spans[0].styles, [.italic])
    }

    func testParseStrikethrough() {
        let (text, spans) = InlineParser.parse("Hello ~~strike~~ world")
        XCTAssertEqual(text, "Hello strike world")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].range, NSRange(location: 6, length: 6))
        XCTAssertEqual(spans[0].styles, [.strikethrough])
    }

    func testParseCode() {
        let (text, spans) = InlineParser.parse("`code`")
        XCTAssertEqual(text, "code")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].range, NSRange(location: 0, length: 4))
        XCTAssertEqual(spans[0].styles, [.code])
    }

    func testParseCodeInline() {
        let (text, spans) = InlineParser.parse("run `code` here")
        XCTAssertEqual(text, "run code here")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].range, NSRange(location: 4, length: 4))
        XCTAssertEqual(spans[0].styles, [.code])
    }

    func testParseNestedBoldItalic() {
        let (text, spans) = InlineParser.parse("**bold *bi* bold**")
        XCTAssertEqual(text, "bold bi bold")
        XCTAssertEqual(spans.count, 2)
        let bold = spans.first { $0.styles == [.bold] }!
        let italic = spans.first { $0.styles == [.italic] }!
        XCTAssertEqual(bold.range, NSRange(location: 0, length: 12))
        XCTAssertEqual(italic.range, NSRange(location: 5, length: 2))
    }

    func testParseMultipleFormats() {
        let (text, spans) = InlineParser.parse("**bold** and *italic*")
        XCTAssertEqual(text, "bold and italic")
        XCTAssertEqual(spans.count, 2)
        let bold = spans.first { $0.styles == [.bold] }!
        let italic = spans.first { $0.styles == [.italic] }!
        XCTAssertEqual(bold.range, NSRange(location: 0, length: 4))
        XCTAssertEqual(italic.range, NSRange(location: 9, length: 6))
    }

    func testParseCodeProtectsFromOtherFormatting() {
        let (text, spans) = InlineParser.parse("`**not bold**`")
        XCTAssertEqual(text, "**not bold**")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].styles, [.code])
    }

    func testParseBoldAndStrikethrough() {
        let (text, spans) = InlineParser.parse("**bold** ~~strike~~")
        XCTAssertEqual(text, "bold strike")
        XCTAssertEqual(spans.count, 2)
        let bold = spans.first { $0.styles == [.bold] }!
        let strike = spans.first { $0.styles == [.strikethrough] }!
        XCTAssertEqual(bold.range, NSRange(location: 0, length: 4))
        XCTAssertEqual(strike.range, NSRange(location: 5, length: 6))
    }

    // MARK: - InlineSerializer

    func testSerializeNoSpans() {
        let result = InlineSerializer.serialize(content: "hello", spans: [])
        XCTAssertEqual(result, "hello")
    }

    func testSerializeBold() {
        let result = InlineSerializer.serialize(content: "Hello bold world", spans: [
            InlineSpan(range: NSRange(location: 6, length: 4), styles: [.bold])
        ])
        XCTAssertEqual(result, "Hello **bold** world")
    }

    func testSerializeCode() {
        let result = InlineSerializer.serialize(content: "code here", spans: [
            InlineSpan(range: NSRange(location: 0, length: 4), styles: [.code])
        ])
        XCTAssertEqual(result, "`code` here")
    }

    func testSerializeBoldAndItalic() {
        let result = InlineSerializer.serialize(content: "both", spans: [
            InlineSpan(range: NSRange(location: 0, length: 4), styles: [.bold]),
            InlineSpan(range: NSRange(location: 0, length: 4), styles: [.italic])
        ])
        XCTAssertEqual(result, "***both***")
    }

    // MARK: - Parse/Serialize Round-Trip

    func testInlineRoundTripBold() {
        let original = "Hello **bold** world"
        let (text, spans) = InlineParser.parse(original)
        let serialized = InlineSerializer.serialize(content: text, spans: spans)
        XCTAssertEqual(serialized, original)
    }

    func testInlineRoundTripItalic() {
        let original = "Hello *italic* world"
        let (text, spans) = InlineParser.parse(original)
        let serialized = InlineSerializer.serialize(content: text, spans: spans)
        XCTAssertEqual(serialized, original)
    }

    func testInlineRoundTripStrikethrough() {
        let original = "Hello ~~strike~~ world"
        let (text, spans) = InlineParser.parse(original)
        let serialized = InlineSerializer.serialize(content: text, spans: spans)
        XCTAssertEqual(serialized, original)
    }

    func testInlineRoundTripCode() {
        let original = "run `code` here"
        let (text, spans) = InlineParser.parse(original)
        let serialized = InlineSerializer.serialize(content: text, spans: spans)
        XCTAssertEqual(serialized, original)
    }

    func testInlineRoundTripNested() {
        let original = "**bold *bi* bold**"
        let (text, spans) = InlineParser.parse(original)
        let serialized = InlineSerializer.serialize(content: text, spans: spans)
        XCTAssertEqual(serialized, original)
    }

    func testInlineRoundTripMultiple() {
        let original = "**bold** and *italic*"
        let (text, spans) = InlineParser.parse(original)
        let serialized = InlineSerializer.serialize(content: text, spans: spans)
        XCTAssertEqual(serialized, original)
    }

    func testSerializeEmptyContent() {
        let result = InlineSerializer.serialize(content: "", spans: [
            InlineSpan(range: NSRange(location: 0, length: 0), styles: [.bold])
        ])
        XCTAssertEqual(result, "")
    }

    func testSerializeZeroLengthSpansSkipped() {
        let result = InlineSerializer.serialize(content: "hello", spans: [
            InlineSpan(range: NSRange(location: 0, length: 0), styles: [.bold])
        ])
        XCTAssertEqual(result, "hello")
    }

    func testSerializeAdjacentSameStyleMerged() {
        let result = InlineSerializer.serialize(content: "abcdef", spans: [
            InlineSpan(range: NSRange(location: 0, length: 3), styles: [.bold]),
            InlineSpan(range: NSRange(location: 3, length: 3), styles: [.bold])
        ])
        XCTAssertEqual(result, "**abcdef**")
    }

    func testSerializeStrikethrough() {
        let result = InlineSerializer.serialize(content: "Hello strike world", spans: [
            InlineSpan(range: NSRange(location: 6, length: 6), styles: [.strikethrough])
        ])
        XCTAssertEqual(result, "Hello ~~strike~~ world")
    }

    // MARK: - InlineSpan Normalization

    func testNormalizedEmpty() {
        XCTAssertEqual(InlineSpan.normalized([]), [])
    }

    func testNormalizedRemovesZeroLength() {
        let spans = [InlineSpan(range: NSRange(location: 0, length: 0), styles: [.bold])]
        XCTAssertEqual(InlineSpan.normalized(spans), [])
    }

    func testNormalizedRemovesEmptyStyles() {
        let spans = [InlineSpan(range: NSRange(location: 0, length: 5), styles: [])]
        XCTAssertEqual(InlineSpan.normalized(spans), [])
    }

    func testNormalizedMergesAdjacent() {
        let spans = [
            InlineSpan(range: NSRange(location: 0, length: 3), styles: [.bold]),
            InlineSpan(range: NSRange(location: 3, length: 3), styles: [.bold])
        ]
        let result = InlineSpan.normalized(spans)
        XCTAssertEqual(result, [InlineSpan(range: NSRange(location: 0, length: 6), styles: [.bold])])
    }

    func testNormalizedMergesOverlapping() {
        let spans = [
            InlineSpan(range: NSRange(location: 0, length: 5), styles: [.bold]),
            InlineSpan(range: NSRange(location: 3, length: 5), styles: [.bold])
        ]
        let result = InlineSpan.normalized(spans)
        XCTAssertEqual(result, [InlineSpan(range: NSRange(location: 0, length: 8), styles: [.bold])])
    }

    func testNormalizedSplitsMultipleStyles() {
        let spans = [
            InlineSpan(range: NSRange(location: 0, length: 5), styles: [.bold, .italic])
        ]
        let result = InlineSpan.normalized(spans)
        XCTAssertEqual(result.count, 2)
        let bold = result.first { $0.styles == [.bold] }
        let italic = result.first { $0.styles == [.italic] }
        XCTAssertEqual(bold?.range, NSRange(location: 0, length: 5))
        XCTAssertEqual(italic?.range, NSRange(location: 0, length: 5))
    }

    func testNormalizedSortsByPosition() {
        let spans = [
            InlineSpan(range: NSRange(location: 5, length: 3), styles: [.italic]),
            InlineSpan(range: NSRange(location: 0, length: 3), styles: [.bold])
        ]
        let result = InlineSpan.normalized(spans)
        XCTAssertEqual(result[0].range.location, 0)
        XCTAssertEqual(result[1].range.location, 5)
    }

}
