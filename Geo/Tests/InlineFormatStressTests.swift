import XCTest
@testable import Geo

final class InlineFormatStressTests: XCTestCase {

    private func styles(_ spans: [InlineSpan]) -> [InlineStyle] {
        spans.flatMap { Array($0.styles) }
    }

    private func hasStyle(_ spans: [InlineSpan], _ predicate: (InlineStyle) -> Bool) -> Bool {
        spans.contains { $0.styles.contains(where: predicate) }
    }

    private func hasCode(_ spans: [InlineSpan]) -> Bool {
        hasStyle(spans) { if case .code = $0 { return true } else { return false } }
    }

    private func hasMath(_ spans: [InlineSpan]) -> Bool {
        hasStyle(spans) { if case .math = $0 { return true } else { return false } }
    }

    private func hasBold(_ spans: [InlineSpan]) -> Bool {
        hasStyle(spans) { if case .bold = $0 { return true } else { return false } }
    }

    private func hasWiki(_ spans: [InlineSpan]) -> Bool {
        hasStyle(spans) {
            if case .wikiLink = $0 { return true }
            if case .wikiLinkWithMeta = $0 { return true }
            return false
        }
    }

    private func hasLink(_ spans: [InlineSpan]) -> Bool {
        hasStyle(spans) { if case .link = $0 { return true } else { return false } }
    }

    private func hasTag(_ spans: [InlineSpan]) -> Bool {
        hasStyle(spans) { if case .tag = $0 { return true } else { return false } }
    }

    // BUG 1: wikilink inside backticks is parsed as a wikilink (code-span exclusion not honored
    // because wikilink pass runs before code pass and code pass doesn't suppress prior wiki matches).
    func testWikiLinkInsideBackticksIsNotLiteral() {
        let (clean, spans) = InlineParser.parse("`[[fake]]`")
        XCTAssertFalse(hasWiki(spans), "`[[fake]]` should render literally, not as a wikilink. clean=\(clean)")
    }

    // BUG 2: math inside backticks is parsed as math.
    func testMathInsideBackticksIsNotMath() {
        let (clean, spans) = InlineParser.parse("`$x$`")
        XCTAssertFalse(hasMath(spans), "`$x$` should not be math inside code. clean=\(clean)")
        XCTAssertTrue(hasCode(spans), "`$x$` should remain a code span. clean=\(clean)")
    }

    // BUG 3: dollar amounts adjacent collapse: `$5$10` becomes a math span over `5`.
    func testAdjacentDollarAmountsParseAsMath() {
        let (_, spans) = InlineParser.parse("Total $5$10 USD")
        XCTAssertFalse(hasMath(spans), "Adjacent dollar amounts should not be treated as math.")
    }

    // BUG 4: escaped square brackets are still parsed as a markdown link.
    func testEscapedBracketsStillParseAsLink() {
        let (_, spans) = InlineParser.parse("\\[not a link\\](https://example.com)")
        XCTAssertFalse(hasLink(spans), "Backslash-escaped brackets should not produce a link.")
    }

    // BUG 5: nested parens in markdown link URL truncate the URL at the first `)`.
    func testLinkURLWithNestedParensTruncates() {
        let (clean, spans) = InlineParser.parse("[wiki](https://example.com/(x))")
        var capturedURL: String? = nil
        for s in spans {
            for style in s.styles {
                if case .link(let u) = style { capturedURL = u }
            }
        }
        XCTAssertEqual(capturedURL, "https://example.com/(x)", "Nested parens in link URL should be preserved (currently truncated). clean=\(clean)")
    }

    // BUG 6: empty target wikilink `[[|alias]]` is accepted with target == "" and an alias.
    func testEmptyTargetAliasWikilinkAccepted() {
        let (clean, spans) = InlineParser.parse("[[|alias]]")
        var emptyTarget = false
        for s in spans {
            for style in s.styles {
                if case .wikiLinkWithMeta(let t, _, _) = style, t.isEmpty { emptyTarget = true }
            }
        }
        XCTAssertFalse(emptyTarget, "`[[|alias]]` should not produce an empty-target wikilink. clean=\(clean)")
    }

    // BUG 7: empty-alias wikilink `[[Page|]]` silently drops the wikilink span and reveals `Page` as plain text.
    func testEmptyAliasWikilinkLosesStyle() {
        let (clean, spans) = InlineParser.parse("[[Page|]]")
        XCTAssertEqual(clean, "[[Page|]]", "Empty-alias wikilink should round-trip unchanged or keep wiki styling — currently it collapses to `Page` with no span.")
        XCTAssertTrue(hasWiki(spans), "Empty-alias wikilink lost its wiki span.")
    }

    // BUG 8: wikilink with surrounding whitespace `[[ Page ]]` does not round-trip cleanly.
    func testWikilinkWhitespaceRoundTrip() {
        let original = "[[ Page ]]"
        let (clean, spans) = InlineParser.parse(original)
        let serialized = InlineSerializer.serialize(content: clean, spans: spans)
        XCTAssertEqual(serialized, original, "Whitespace-padded wikilink should round-trip; currently rewritten with alias syntax.")
    }

    // BUG 9: tag inside markdown link text is still styled as a tag (no link-exclusion for tags).
    func testTagInsideLinkTextStillTagged() {
        let (_, spans) = InlineParser.parse("[hello #world](https://x.com)")
        XCTAssertFalse(hasTag(spans), "`#world` inside link text should not be a tag.")
    }

    // BUG 10: tag adjacent to a comma `,#tag` is silently rejected (boundary class only allows ws/`(`).
    func testTagAfterPunctuationDoesNotMatch() {
        let (_, spans) = InlineParser.parse("hello,#tag")
        XCTAssertTrue(hasTag(spans), "`#tag` after `,` should still parse as a tag. Inline parser's tag boundary class is too restrictive.")
    }

    // BUG 11: AutoFormatEngine.findInlinePattern("**") on `***bold***` matches inner pair and
    // captures `bold**` as content (length 6) instead of `bold` (length 4).
    func testTripleStarAutoFormatMisalignsContent() {
        let engine = AutoFormatEngine()
        let text = "***bold***" as NSString
        // Cursor sits just past the last `*` (length 10).
        let result = engine.findInlinePattern(marker: "**", at: text.length, in: text)
        XCTAssertNotNil(result)
        let content = text.substring(with: result!.contentRange)
        XCTAssertEqual(content, "bold", "Triple-star sequence should isolate bold over `bold`, not `bold**`. Got `\(content)`.")
    }

    // BUG 12: SpanStyler mutates text storage when rendering math, which invalidates the ranges
    // of *subsequent* spans in the same pass and bold ends up on the wrong slice.
    func testMathReplacementCorruptsLaterSpans() {
        let original = "$x$ then **bold**"
        let (clean, spans) = InlineParser.parse(original)
        let ts = NSTextStorage(string: clean)
        let baseFont = NSFont.systemFont(ofSize: 13)
        SpanStyler.apply(spans: spans, to: ts, baseFont: baseFont)

        // After math becomes an attachment (length 1), `bold` should still be the bold-styled text.
        // Pull the range of any bold attribute; it must point at the literal "bold" substring.
        var boldLanded = false
        ts.enumerateAttribute(.font, in: NSRange(location: 0, length: ts.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let boldName = SpanStyler.boldFont(for: baseFont).fontName
            if font.fontName == boldName {
                let substring = (ts.string as NSString).substring(with: range)
                if substring == "bold" { boldLanded = true }
            }
        }
        XCTAssertTrue(boldLanded, "After math replacement, bold styling lands on the wrong substring; text storage = `\(ts.string)`.")
    }

    // BUG 13: code span swallowed when followed immediately by math: `` `code`$x$ `` — math passes first.
    // Verifies relative ordering of code vs math is fine for backtick-then-math, but flips for math-then-backtick.
    func testBackticksAroundMathMarkup() {
        let (_, spans) = InlineParser.parse("`code` and $y$")
        XCTAssertTrue(hasCode(spans))
        XCTAssertTrue(hasMath(spans))
    }

    // BUG 14: round-trip on bold-italic preserves both styles via serialize.
    func testBoldItalicRoundTrip() {
        let original = "**bold *italic* bold**"
        let (clean, spans) = InlineParser.parse(original)
        let out = InlineSerializer.serialize(content: clean, spans: spans)
        XCTAssertEqual(out, original, "Bold-italic nested markdown should round-trip identically.")
    }

    // BUG 15: highlight delimiter pair `==a====b==` should give two highlights.
    func testTouchingHighlightPair() {
        let (_, spans) = InlineParser.parse("==a====b==")
        let hi = spans.filter { $0.styles.contains(.highlight) }
        XCTAssertEqual(hi.count, 2, "Two touching `==..==` runs should give two highlight spans, got \(hi.count).")
    }

    // BUG 16: italic with underscore `_italic_` is not parsed (italic regex only accepts `*`).
    func testUnderscoreItalicNotParsed() {
        let (_, spans) = InlineParser.parse("_italic_")
        let isItalic = spans.contains { $0.styles.contains(.italic) }
        XCTAssertTrue(isItalic, "`_italic_` should produce an italic span; the regex currently only honors `*`.")
    }

    func testIntraWordUnderscoreNotItalic() {
        let (clean, spans) = InlineParser.parse("foo_bar_baz")
        XCTAssertEqual(clean, "foo_bar_baz")
        let isItalic = spans.contains { $0.styles.contains(.italic) }
        XCTAssertFalse(isItalic, "Intra-word underscores should not produce italic.")
    }

    func testWikilinkAcrossNewlinesRejected() {
        let (_, spans) = InlineParser.parse("[[A\nB]]")
        XCTAssertFalse(hasWiki(spans), "Wikilinks must not cross newlines.")
    }

    func testMathAcrossNewlinesRejected() {
        let (_, spans) = InlineParser.parse("$x\ny$")
        XCTAssertFalse(hasMath(spans), "Inline math must not cross newlines.")
    }

    private func hasAutoLink(_ spans: [InlineSpan]) -> Bool {
        hasStyle(spans) { if case .autoLink = $0 { return true } else { return false } }
    }

    private func autoLinkURL(_ spans: [InlineSpan]) -> String? {
        for s in spans {
            for style in s.styles {
                if case .autoLink(let u) = style { return u }
            }
        }
        return nil
    }

    func testBareURLBecomesAutoLink() {
        let (clean, spans) = InlineParser.parse("see https://example.com/x?a=1 now")
        XCTAssertTrue(hasAutoLink(spans), "Bare http(s) URL should produce an auto-link. clean=\(clean)")
        XCTAssertEqual(autoLinkURL(spans), "https://example.com/x?a=1")
        XCTAssertEqual(clean, "see https://example.com/x?a=1 now", "Auto-link must not strip any characters.")
    }

    func testBareURLInsideCodeIsNotLinked() {
        let (_, spans) = InlineParser.parse("`https://example.com`")
        XCTAssertFalse(hasAutoLink(spans), "URL inside a code span must not be auto-linked.")
        XCTAssertTrue(hasCode(spans))
    }

    func testBareURLInsideWikiIsNotLinked() {
        let (_, spans) = InlineParser.parse("[[https://example.com|alias]]")
        XCTAssertFalse(hasAutoLink(spans), "URL inside a wikilink must not be auto-linked.")
        XCTAssertTrue(hasWiki(spans))
    }

    func testBareURLInsideMathIsNotLinked() {
        let (_, spans) = InlineParser.parse("$https://example.com$")
        XCTAssertFalse(hasAutoLink(spans), "URL inside a math span must not be auto-linked.")
    }

    func testBareURLInsideMarkdownLinkIsNotDoubleLinked() {
        let (_, spans) = InlineParser.parse("[label](https://example.com)")
        XCTAssertFalse(hasAutoLink(spans), "URL inside an existing markdown link must not also auto-link.")
        XCTAssertTrue(hasLink(spans))
    }

    func testBareURLRoundTripPreservesSource() {
        let original = "before https://example.com/path?q=1#frag after"
        let (clean, spans) = InlineParser.parse(original)
        let serialized = InlineSerializer.serialize(content: clean, spans: spans)
        XCTAssertEqual(serialized, original, "Auto-link round-trip must reproduce the raw URL, never inject []().")
    }

    func testBareURLWithUnderscoresIsNotItalicized() {
        let original = "see https://en.wikipedia.org/wiki/Foo_bar_baz now"
        let (clean, spans) = InlineParser.parse(original)
        XCTAssertEqual(autoLinkURL(spans), "https://en.wikipedia.org/wiki/Foo_bar_baz")
        XCTAssertEqual(clean, original, "Underscores inside a URL must not be stripped as italic markers.")
        XCTAssertEqual(InlineSerializer.serialize(content: clean, spans: spans), original)
    }

    func testBareURLWithSpecialCharsRoundTrips() {
        for original in [
            "x https://example.com/a*b*c y",
            "x https://example.com/a~~b~~c y",
            "x https://example.com/a==b==c y"
        ] {
            let (clean, spans) = InlineParser.parse(original)
            XCTAssertEqual(clean, original, "Markup chars inside a URL must survive parse: \(original)")
            XCTAssertEqual(InlineSerializer.serialize(content: clean, spans: spans), original, "Round-trip must reproduce: \(original)")
        }
    }
}
