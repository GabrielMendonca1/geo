import XCTest
@testable import Geo

@MainActor
final class AutoFormatAndOverlaysStressTests: XCTestCase {

    // MARK: - BlockPrefixDetector edge cases

    func testPrefix_leadingTabHashSpace_returnsNil_inspect() {
        XCTAssertNil(BlockPrefixDetector.detect("\t# "))
        XCTAssertNil(BlockPrefixDetector.detect(" # "))
        XCTAssertNil(BlockPrefixDetector.detect("  ### "))
    }

    func testPrefix_zeroDotSpace_convertsToOrderedZero() {
        XCTAssertEqual(
            BlockPrefixDetector.detect("0. "),
            .convert(kind: .orderedItem(number: 0), remainingContent: "")
        )
    }

    func testPrefix_signedOrdered_acceptsPlusAndMinus() {
        XCTAssertEqual(
            BlockPrefixDetector.detect("+1. "),
            .convert(kind: .orderedItem(number: 1), remainingContent: "")
        )
        XCTAssertEqual(
            BlockPrefixDetector.detect("-1. "),
            .convert(kind: .orderedItem(number: -1), remainingContent: "")
        )
    }

    func testPrefix_hugeNumber_overflowsToNil() {
        XCTAssertNil(BlockPrefixDetector.detect("99999999999999999999. "))
    }

    func testPrefix_largeButValidInt_converts() {
        XCTAssertEqual(
            BlockPrefixDetector.detect("1234567890. "),
            .convert(kind: .orderedItem(number: 1234567890), remainingContent: "")
        )
    }

    func testPrefix_whitespaceOnlyContent_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("   "))
        XCTAssertNil(BlockPrefixDetector.detect(" "))
        XCTAssertNil(BlockPrefixDetector.detect(""))
    }

    func testPrefix_sevenHashes_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("####### "))
    }

    func testPrefix_orderedItemDoesNotReConvert_inspect() {
        XCTAssertEqual(
            BlockPrefixDetector.detect("2. "),
            .convert(kind: .orderedItem(number: 2), remainingContent: "")
        )
    }

    // MARK: - Slash command filter

    func testSlash_filtered_emptyFilter_returnsAll() {
        let id = UUID()
        let state = SlashState(blockId: id, blockIndex: 0, filter: "", selectedIndex: 0)
        let all = SlashCommandOverlay.filtered(for: id, slashState: state)
        XCTAssertEqual(all.count, BlockSlashCommand.all.count)
    }

    func testSlash_filtered_blockIdMismatch_returnsEmpty() {
        let stateId = UUID()
        let viewId = UUID()
        let state = SlashState(blockId: stateId, blockIndex: 0, filter: "", selectedIndex: 0)
        XCTAssertTrue(SlashCommandOverlay.filtered(for: viewId, slashState: state).isEmpty)
    }

    func testSlash_filtered_h1_matchesHeading1() {
        let id = UUID()
        let state = SlashState(blockId: id, blockIndex: 0, filter: "h1", selectedIndex: 0)
        let results = SlashCommandOverlay.filtered(for: id, slashState: state)
        XCTAssertTrue(results.contains(where: { $0.id == "h1" }))
        XCTAssertFalse(results.contains(where: { $0.id == "h2" }))
    }

    func testSlash_filtered_multiWord_heading1_matchesLabel() {
        let id = UUID()
        let state = SlashState(blockId: id, blockIndex: 0, filter: "heading 1", selectedIndex: 0)
        let results = SlashCommandOverlay.filtered(for: id, slashState: state)
        XCTAssertTrue(results.contains(where: { $0.id == "h1" }))
    }

    func testSlash_filtered_aliasIsPrefixOnly() {
        let id = UUID()
        let state = SlashState(blockId: id, blockIndex: 0, filter: "ist", selectedIndex: 0)
        let results = SlashCommandOverlay.filtered(for: id, slashState: state)
        XCTAssertTrue(
            results.contains(where: { $0.id == "bullet" }),
            "Slash matches labels/aliases by contains, so substring 'ist' matches 'Bullet List' / alias 'list'."
        )
    }

    // MARK: - Mention overlay filter

    func testMentionFiltered_emptyState() {
        XCTAssertTrue(MentionOverlay.filtered(mentionState: nil, mentionableBlocks: []).isEmpty)
    }

    func testMentionFiltered_emptyFilter_returnsUpTo8() {
        let id = UUID()
        let state = MentionState(blockId: id, blockIndex: 0, filter: "", selectedIndex: 0)
        let mentionables = (0..<12).map { BlockMentionItem(id: "id\($0)", title: "Title \($0)") }
        let results = MentionOverlay.filtered(mentionState: state, mentionableBlocks: mentionables)
        XCTAssertEqual(results.count, 8)
    }

    func testMentionFiltered_substringMatch() {
        let id = UUID()
        let state = MentionState(blockId: id, blockIndex: 0, filter: "ist", selectedIndex: 0)
        let mentionables = [
            BlockMentionItem(id: "1", title: "Bullet list"),
            BlockMentionItem(id: "2", title: "History"),
            BlockMentionItem(id: "3", title: "Plain"),
        ]
        let results = MentionOverlay.filtered(mentionState: state, mentionableBlocks: mentionables)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains(where: { $0.id == "1" }))
        XCTAssertTrue(results.contains(where: { $0.id == "2" }))
    }

    func testSlashVsMention_filterSemanticsDiffer() {
        let id = UUID()
        let slashState = SlashState(blockId: id, blockIndex: 0, filter: "ist", selectedIndex: 0)
        let mentionState = MentionState(blockId: id, blockIndex: 0, filter: "ist", selectedIndex: 0)
        let slashResults = SlashCommandOverlay.filtered(for: id, slashState: slashState)
        let mentionItems = [BlockMentionItem(id: "1", title: "list")]
        let mentionResults = MentionOverlay.filtered(mentionState: mentionState, mentionableBlocks: mentionItems)
        XCTAssertTrue(
            slashResults.contains(where: { $0.id == "bullet" }),
            "Unified contains() semantic: slash 'ist' matches 'Bullet List' / alias 'list'."
        )
        XCTAssertEqual(mentionResults.count, 1, "Mention uses contains(), so 'ist' matches 'list'.")
    }

    func testMention_dismissCheckIgnoresCaretPosition_inspect() {
        let s = "[[A]] then plain text"
        XCTAssertTrue(
            s.contains("[["),
            "BlockNSTextView.deleteBackward dismisses mention only when '[[' is absent — but here the closed mention keeps the substring present even though the caret is in plain text."
        )
    }

    // MARK: - Outline extractor

    func testOutlineExtractor_idsAreStableAcrossCalls() {
        let raw = "# Hello\n"
        let doc = BlockEditorDocument(markdown: raw)
        let first = OutlineExtractor.headings(from: doc.blocks)
        let second = OutlineExtractor.headings(from: doc.blocks)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(first[0].blockId, second[0].blockId)
        XCTAssertEqual(first[0].title, second[0].title)
        XCTAssertEqual(
            first[0].id, second[0].id,
            "OutlineHeading.id derives from blockId — stable across calls so SwiftUI ForEach diffs cleanly."
        )
    }

    func testOutlineExtractor_emptyDocument_returnsEmpty() {
        let doc = BlockEditorDocument(markdown: "Just a paragraph.\n")
        XCTAssertTrue(OutlineExtractor.headings(from: doc.blocks).isEmpty)
    }

    func testOutlineExtractor_extractsMultipleLevels() {
        let raw = """
        # One
        ## Two
        ### Three

        body

        ## Two Again
        """
        let doc = BlockEditorDocument(markdown: raw)
        let headings = OutlineExtractor.headings(from: doc.blocks)
        XCTAssertEqual(headings.count, 4)
        XCTAssertEqual(headings.map(\.level), [1, 2, 3, 2])
        XCTAssertEqual(headings.map(\.title), ["One", "Two", "Three", "Two Again"])
    }

    func testOutline_depthSixIndent_isClampedAtLevel4() {
        XCTAssertEqual(OutlinePopover.leadingPad(forLevel: 1), 12)
        XCTAssertEqual(OutlinePopover.leadingPad(forLevel: 4), 48)
        XCTAssertEqual(OutlinePopover.leadingPad(forLevel: 5), 48, "Clamp at 4 to prevent label clipping on 260pt-wide popover.")
        XCTAssertEqual(OutlinePopover.leadingPad(forLevel: 6), 48)
    }

    // MARK: - PendingAnchorStore

    func testPendingAnchor_enqueueAndConsume_roundTrip() {
        let store = PendingAnchorStore.shared
        let key = "test-anchor-\(UUID().uuidString)"
        store.enqueue(blockId: key, anchor: "Intro")
        XCTAssertEqual(store.consume(blockId: key), "Intro")
        XCTAssertNil(store.consume(blockId: key))
    }

    func testPendingAnchor_overwriteSemantics() {
        let store = PendingAnchorStore.shared
        let key = "test-overwrite-\(UUID().uuidString)"
        store.enqueue(blockId: key, anchor: "First")
        store.enqueue(blockId: key, anchor: "Second")
        XCTAssertEqual(
            store.consume(blockId: key), "First",
            "FIFO queue — first enqueued anchor consumed first."
        )
        XCTAssertEqual(
            store.consume(blockId: key), "Second",
            "Second enqueued anchor consumed next; nothing dropped."
        )
        XCTAssertNil(store.consume(blockId: key))
    }

    func testPendingAnchor_enqueuePostsNotification() {
        let store = PendingAnchorStore.shared
        let key = "test-notif-\(UUID().uuidString)"
        let exp = expectation(forNotification: .geoPendingAnchorChanged, object: nil) { note in
            (note.object as? String) == key
        }
        store.enqueue(blockId: key, anchor: "A")
        wait(for: [exp], timeout: 1.0)
        _ = store.consume(blockId: key)
    }

    func testPendingAnchor_alreadyOpenWindow_inspect() {
        let store = PendingAnchorStore.shared
        let key = "test-orphan-\(UUID().uuidString)"
        store.enqueue(blockId: key, anchor: "Conclusion")
        XCTAssertEqual(store.consume(blockId: key), "Conclusion")
    }

    // MARK: - Heading match (anchor focus)

    func testHeadingMatch_caseInsensitiveASCII() {
        let normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        XCTAssertEqual(normalize("INTRO"), normalize("Intro"))
        XCTAssertEqual(normalize("  intro  "), normalize("Intro"))
    }

    func testHeadingMatch_diacriticsNormalized() {
        XCTAssertEqual(BlockEditorView.normalizeHeading("Café"), BlockEditorView.normalizeHeading("café"))
        XCTAssertEqual(
            BlockEditorView.normalizeHeading("cafe"), BlockEditorView.normalizeHeading("Café"),
            "normalizeHeading folds diacritics, so 'cafe' matches 'Café'."
        )
        XCTAssertEqual(
            BlockEditorView.normalizeHeading("Crème Brûlée"),
            BlockEditorView.normalizeHeading("creme brulee")
        )
    }

    func testHeadingMatch_anchorWithMarkdown_matchesAfterStrip() {
        let raw = "## **Bold** title\n"
        let doc = BlockEditorDocument(markdown: raw)
        guard let block = doc.blocks.first, case .heading = block.kind else {
            return XCTFail("Expected a heading block.")
        }
        let headingNormalized = BlockEditorView.normalizeHeading(block.cleanContent ?? block.content)
        let anchorWithStars = BlockEditorView.normalizeHeading("**Bold** title")
        XCTAssertEqual(headingNormalized, anchorWithStars, "normalizeHeading strips inline markdown so anchor including stars still matches.")
    }

    func testStripInlineMarkdown_handlesAllMarkers() {
        XCTAssertEqual(BlockEditorView.stripInlineMarkdown("**bold**"), "bold")
        XCTAssertEqual(BlockEditorView.stripInlineMarkdown("*italic*"), "italic")
        XCTAssertEqual(BlockEditorView.stripInlineMarkdown("***bolditalic***"), "bolditalic")
        XCTAssertEqual(BlockEditorView.stripInlineMarkdown("`code`"), "code")
        XCTAssertEqual(BlockEditorView.stripInlineMarkdown("__under__"), "under")
        XCTAssertEqual(BlockEditorView.stripInlineMarkdown("~~strike~~"), "strike")
    }

    func testHeadingMatch_anchorWithoutMarkdown_matches() {
        let raw = "## **Bold** title\n"
        let doc = BlockEditorDocument(markdown: raw)
        guard let block = doc.blocks.first else { return XCTFail("Missing block.") }
        let title = (block.cleanContent ?? block.content)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let plainAnchor = "Bold title".trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        XCTAssertEqual(title, plainAnchor)
    }

    func testHeadingMatch_emptyAnchor_returnsNoMatchSemantics() {
        let raw = "# Hello\n"
        let doc = BlockEditorDocument(markdown: raw)
        let normalized = "".trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        XCTAssertTrue(normalized.isEmpty)
        XCTAssertNotNil(doc.blocks.first)
    }

    // MARK: - AutoFormat scan-window inspection

    func testAutoFormat_bold_over200CharsAway_doesNotMatch() {
        let pad = String(repeating: "x", count: 250)
        let raw = "**" + pad + "**" as NSString
        let engine = AutoFormatEngine()
        let match = engine.findInlinePattern(marker: "**", at: raw.length, in: raw)
        XCTAssertNil(match, "Scan window is capped at 200 characters; openers further than 200 chars away are invisible.")
    }

    func testAutoFormat_bold_within200CharsAway_matches() {
        let pad = String(repeating: "x", count: 50)
        let raw = "**" + pad + "**" as NSString
        let engine = AutoFormatEngine()
        let match = engine.findInlinePattern(marker: "**", at: raw.length, in: raw)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.contentRange.length, 50)
    }

    func testAutoFormat_mixedAsterisks_pickWrongOpener() {
        let raw = "*a**b*" as NSString
        let engine = AutoFormatEngine()
        XCTAssertNil(
            engine.findInlinePattern(marker: "**", at: raw.length, in: raw),
            "No proper '**…**' pair, so bold should not fire."
        )
        let italic = engine.findSingleStarPattern(at: raw.length, in: raw)
        XCTAssertNotNil(italic, "Single-star scanner picks SOME opener — content range bleeds across an embedded '*'.")
        if let italic {
            let content = raw.substring(with: italic.contentRange)
            XCTAssertTrue(content.contains("*"), "Italicized span contains a literal '*' — almost certainly wrong.")
        }
    }

    func testAutoFormat_simplePair_isFound() {
        let raw = "**bold**" as NSString
        let engine = AutoFormatEngine()
        let match = engine.findInlinePattern(marker: "**", at: raw.length, in: raw)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.contentRange.length, 4)
    }

    func testAutoFormat_singleStar_noOpener_returnsNil() {
        let raw = "abc*" as NSString
        let engine = AutoFormatEngine()
        XCTAssertNil(engine.findSingleStarPattern(at: raw.length, in: raw))
    }

    func testAutoFormat_singleStar_isolatedPair() {
        let raw = "*it*" as NSString
        let engine = AutoFormatEngine()
        let match = engine.findSingleStarPattern(at: raw.length, in: raw)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.contentRange.length, 2)
    }

    func testAutoFormat_singleUnderscore_isolatedPair() {
        let raw = "_x_" as NSString
        let engine = AutoFormatEngine()
        let match = engine.findSingleUnderscorePattern(at: raw.length, in: raw)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.contentRange.length, 1)
        XCTAssertEqual(raw.substring(with: match!.contentRange), "x")
    }

    func testAutoFormat_intraWordUnderscores_doNotFormat() {
        let engine = AutoFormatEngine()
        let closingOnWord = "foo_bar_" as NSString
        XCTAssertNil(
            engine.findSingleUnderscorePattern(at: closingOnWord.length, in: closingOnWord),
            "Opening '_' is preceded by a word character, so foo_bar_baz must not auto-italicize (CommonMark guard)."
        )
        let trailingWord = "_bar_baz" as NSString
        XCTAssertNil(
            engine.findSingleUnderscorePattern(at: 5, in: trailingWord),
            "Closing '_' is followed by a word character, so it must not auto-italicize."
        )
    }

    func testAutoFormat_singleUnderscore_noOpener_returnsNil() {
        let raw = "abc_" as NSString
        let engine = AutoFormatEngine()
        XCTAssertNil(engine.findSingleUnderscorePattern(at: raw.length, in: raw))
    }

    // MARK: - cmd+K link template

    func testCmdK_emptyCursor_inspect() {
        let inserted = "[]()"
        let cursorOffset = 1
        let ns = inserted as NSString
        let before = ns.substring(to: cursorOffset)
        let after = ns.substring(from: cursorOffset)
        XCTAssertEqual(before, "[")
        XCTAssertEqual(after, "]()")
        let typed = before + "https://example.com" + after
        XCTAssertEqual(
            typed, "[https://example.com]()",
            "Cursor lands between '[' and ']' — user typing a URL gets it as the label, not the link target."
        )
    }

    func testCmdK_selectionInsideWikilink_isNoOp() {
        let ts = NSTextStorage(string: "[[Some Page]]")
        ts.addAttribute(.geoWikiLink, value: true, range: NSRange(location: 0, length: ts.length))
        XCTAssertTrue(TextViewKeyHandler.rangeOverlapsWikilink(NSRange(location: 2, length: 9), in: ts))
        XCTAssertTrue(TextViewKeyHandler.rangeOverlapsWikilink(NSRange(location: 5, length: 0), in: ts))
        let plain = NSTextStorage(string: "plain text")
        XCTAssertFalse(TextViewKeyHandler.rangeOverlapsWikilink(NSRange(location: 0, length: plain.length), in: plain))
        XCTAssertFalse(TextViewKeyHandler.rangeOverlapsWikilink(NSRange(location: 3, length: 0), in: plain))
    }
}
