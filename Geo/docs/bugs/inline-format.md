# Inline format bugs

## [WRONG] Wikilink wins over enclosing backticks
**Repro:** `` `[[fake]]` ``
**Expected:** Code span renders `[[fake]]` literally with no wikilink styling.
**Actual:** Wikilink pass runs first and consumes `[[fake]]`. The code pass also matches the outer backticks (it only suppresses overlap with prior math matches, not wikilink matches). Both spans land on the same content range; markers from both passes are removed, so the cleaned text becomes `fake` and gets styled as a clickable wikilink AND code.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:85-123` (wikilink loop has no awareness of code) and `:142-149` (code loop skips math via `isInsideMath` but does not skip wikilink overlap).
**Test:** `Tests/InlineFormatStressTests.swift::testWikiLinkInsideBackticksIsNotLiteral`

## [WRONG] Math wins over enclosing backticks
**Repro:** `` `$x$` ``
**Expected:** `` `$x$` `` is a literal code span; math should not render.
**Actual:** Math pass at line 127 runs before code (line 142). It matches `$x$` and is added to `mathFullRanges`. The code pass then encounters the outer backticks and skips them because `isInsideMath(m.range)` is true. Net effect: `x` is rendered as math, backticks remain in cleaned text, code span is lost.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:127-134` (math runs before code) and `:142-143` (code unconditionally skips anything overlapping math).
**Test:** `Tests/InlineFormatStressTests.swift::testMathInsideBackticksIsNotMath`

## [WRONG] Adjacent dollar amounts parsed as math
**Repro:** `Total $5$10 USD`
**Expected:** Two dollar amounts side by side should not be inline math.
**Actual:** `mathRegex` (`(?<!\$)\$(\S[^$]*?\S|\S)\$(?!\$)`) accepts the single-char alternative `\S`, so `$5$` (open `$`, content `5`, close `$`) matches because the char after the closing `$` is `1` (not `$`). `5` becomes a math equation.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:72`
**Test:** `Tests/InlineFormatStressTests.swift::testAdjacentDollarAmountsParseAsMath`

## [WRONG] Escaped brackets still produce a markdown link
**Repro:** `\[not a link\](https://example.com)`
**Expected:** Backslash-escaped brackets should be treated as literal text.
**Actual:** `linkRegex` has only a `(?<!\[)` lookbehind. A leading backslash satisfies that lookbehind, so `[not a link](https://example.com)` is matched as a normal link and the backslashes survive in cleaned text adjacent to the rendered link text.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:66`
**Test:** `Tests/InlineFormatStressTests.swift::testEscapedBracketsStillParseAsLink`

## [LOSSY] Nested parentheses in link URL are truncated
**Repro:** `[wiki](https://example.com/(x))`
**Expected:** URL `https://example.com/(x)`.
**Actual:** `linkRegex` URL group is `[^)]+`, which stops at the first `)`. The captured URL becomes `https://example.com/(x` and the closing `)` is left as a literal character in the cleaned text after the link.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:66`
**Test:** `Tests/InlineFormatStressTests.swift::testLinkURLWithNestedParensTruncates`

## [WRONG] Empty-target wikilink `[[|alias]]` accepted with `target == ""`
**Repro:** `[[|alias]]`
**Expected:** Either rejected or treated as literal text.
**Actual:** `firstIndex(of: "|")` returns offset 0, `pageRaw` is `""`, target is set to empty string, alias content `alias` is captured and a `.wikiLinkWithMeta(target: "", anchor: nil, isEmbed: false)` span is emitted. Click handlers downstream will be asked to resolve an empty page title.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:93-100, 109-111`
**Test:** `Tests/InlineFormatStressTests.swift::testEmptyTargetAliasWikilinkAccepted`

## [LOSSY] Empty-alias wikilink `[[Page|]]` silently loses styling
**Repro:** `[[Page|]]`
**Expected:** Either an error, the literal text preserved, or wikilink styling over the visible `Page`.
**Actual:** Alias content length is computed as `NSMaxRange(innerRange) - alias - 1` which evaluates to 0 for an empty alias. A zero-length contentRange is added; the marker set still strips the `[[`, `|`, `]]`. After `length > 0` filter at line 218 the span is dropped, so the cleaned text is `Page` with no wikilink span at all.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:110-115, 218-221`
**Test:** `Tests/InlineFormatStressTests.swift::testEmptyAliasWikilinkLosesStyle`

## [LOSSY] Whitespace-padded wikilink mangled on round-trip
**Repro:** Markdown `[[ Page ]]` → parse → serialize.
**Expected:** Round-trip to `[[ Page ]]`.
**Actual:** Parser trims the target to `Page` but leaves the content range as `" Page "`. Serializer's `pageWithAnchor` is `Page` and the upcoming content is `" Page "` — they differ, so serializer emits the alias form: `[[Page| Page ]]`.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:108` (trim), `InlineSerializer` `:308-323`
**Test:** `Tests/InlineFormatStressTests.swift::testWikilinkWhitespaceRoundTrip`

## [WRONG] Tag inside markdown link text still tagged
**Repro:** `[hello #world](https://x.com)`
**Expected:** `#world` is link text, not a tag.
**Actual:** Tag loop excludes wikilink/code/math but not link spans, so `#world` is added as a `.tag` style on top of the existing link span. Tag styling (color teal) clobbers link styling (color systemBlue).
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:182-187` (no `isInsideLink` check)
**Test:** `Tests/InlineFormatStressTests.swift::testTagInsideLinkTextStillTagged`

## [MINOR] Tag boundary class drops common punctuation
**Repro:** `hello,#tag`, `;#tag`, `\u{2014}#tag` (em-dash)
**Expected:** Tag detection after typical inline punctuation.
**Actual:** `tagRegex` accepts only `^|[\s(]` as the preceding character, so any tag adjacent to `,`, `;`, `:`, `—`, `/`, `]`, `}`, etc. is silently ignored.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:73`
**Test:** `Tests/InlineFormatStressTests.swift::testTagAfterPunctuationDoesNotMatch`

## [WRONG] AutoFormat triple-star misaligns content
**Repro:** Type `***bold***`. With cursor right after the trailing `*` (length 10), `AutoFormatEngine.findInlinePattern("**", …)` is called.
**Expected:** Match the inner `**bold**` so bold styling applies to `bold`.
**Actual:** Scan starts at `closeStart - 1 = 7` and walks backward two-char windows looking for `**`. The first window that matches is at positions 1..3 (`**`), giving `openRange = (1, 2)`, `closeRange = (8, 2)`, `contentRange = (3, 6)`. The content is `bold**`, not `bold`. After `applyInlineAutoFormat` strips the two outer pairs, the surviving text is `*bold**` with bold styling on `bold**`.
**Where:** `Shared/DesignSystem/Editor/AutoFormatEngine.swift:48-76`
**Test:** `Tests/InlineFormatStressTests.swift::testTripleStarAutoFormatMisalignsContent`

## [WRONG] SpanStyler mutates text storage and breaks later spans
**Repro:** Markdown `$x$ then **bold**` → parse → `SpanStyler.apply`.
**Expected:** After math is rendered as an attachment (length 1), bold styling lands on the word `bold`.
**Actual:** `SpanStyler.apply` iterates spans in parse order and calls `ts.replaceCharacters(in: r, with: rendered)` for math at line 472. The math LaTeX content is replaced with a single attachment glyph (length 1), shrinking the storage. Subsequent spans in the same loop still hold their pre-replacement ranges; `NSIntersectionRange` clips them silently so no crash, but bold/italic/code/etc. styling ends up on the wrong substring (or empty).
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:412-486` (loop mutates `ts` inside the iteration)
**Test:** `Tests/InlineFormatStressTests.swift::testMathReplacementCorruptsLaterSpans`

## [WRONG] Bold-italic nested markdown does not round-trip
**Repro:** `**bold *italic* bold**`
**Expected:** Round-trip to itself.
**Actual:** Parser produces correct nested spans, but `InlineSerializer.serialize` emits markers strictly by `closeOrder = [.wikiLink, .code, .highlight, .strikethrough, .italic, .bold]` and `openOrder = [.bold, .italic, .strikethrough, .highlight, .code, .wikiLink]`. When the italic closes inside the bold span, the close order at that boundary emits `*` first then nothing for bold (bold has no boundary there) — but the italic open earlier emitted `*` immediately after `**`, producing `***italic*` rather than `**bold *italic*`. Output drifts (verify exact string in test).
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:227-336`
**Test:** `Tests/InlineFormatStressTests.swift::testBoldItalicRoundTrip`

## [MINOR] Touching highlight pair `==a====b==` may collapse
**Repro:** `==a====b==`
**Expected:** Two highlight spans (`a` and `b`).
**Actual:** Lazy `==(.+?)==` should produce two matches, but the regex engine's non-overlapping behavior can produce a single match with content `a====b` if it greedily skips past inner `==`. Worth confirming with a unit test (regex is lazy so theoretically two matches).
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:71`
**Test:** `Tests/InlineFormatStressTests.swift::testTouchingHighlightPair`

## [MINOR] Underscore italics not supported
**Repro:** `_italic_`
**Expected:** Italic span over `italic` (standard CommonMark).
**Actual:** `italicRegex` matches only `*`, never `_`. Users coming from CommonMark/Obsidian-style underscore italics see no styling.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:69`
**Test:** `Tests/InlineFormatStressTests.swift::testUnderscoreItalicNotParsed`

## [SUSPECT] AutoFormat 200-char hard scan limit silently disables long pairs (REJECTED: intentional scan-cost guardrail; user can re-type the close inside the limit. No correctness issue, only UX surprise. Not in scope for the inline-format slice.)
**Repro:** Type `**` more than 200 characters apart then close with `**`.
**Expected:** Either succeed or surface that the pair was too long to auto-format.
**Actual:** `scanLimit = max(markerLen, closeStart - 200)` aborts the search after 200 characters with no feedback; the closing `**` is just typed and no formatting is applied. The asymmetry (works for short, mysteriously fails for long) is confusing.
**Where:** `Shared/DesignSystem/Editor/AutoFormatEngine.swift:58, :86`

## [SUSPECT] Wikilink regex matches across newlines (CONFIRMED — fixed)
**Repro:** `[[A\nB]]` (literal newline inside `[[...]]`)
**Expected:** Reject — wikilink targets are single-line by convention.
**Actual:** `[^\[\]]+` allows newlines, so the parser produces a multi-line wikilink. Likely interacts poorly with the block parser (which splits on newlines) and inline rendering.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:65`
**Fix:** Updated regex to `[^\[\]\n]*`. Test `testWikilinkAcrossNewlinesRejected` added.

## [SUSPECT] Math regex `[^$]*?` allows multi-line math (CONFIRMED — fixed)
**Repro:** `$x\ny$`
**Expected:** Inline math is single line; block math uses `$$ ... $$`.
**Actual:** `[^$]*?` accepts newlines and the `\S...\S` anchors don't forbid them, so a stray pair of `$`s straddling a line break renders as math.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:72`
**Fix:** Tightened math regex to `[^$\n]*?` and forbid digit-bounded `$`. Test `testMathAcrossNewlinesRejected` added.

## [SUSPECT] Wikilink anchor with caret keeps the caret in `anchor` string (REJECTED: bug doc concedes it is intentional. Serializer already round-trips both `#` and `^` correctly. Schema change would be a behavior break across consumers; not justified.)
**Repro:** `[[Page^block-id]]`
**Expected:** Either store `anchor = "block-id"` or store `anchor = "^block-id"` consistently — the calling code at the serializer (`InlineFormat.swift:312`) special-cases `anchor.hasPrefix("^")`, which suggests this is intentional but is at odds with the `#` branch that strips the `#`.
**Actual:** For `#` anchors the `#` is stripped before being stored (`InlineFormat.swift:102`). For `^` anchors the `^` is kept (`:105`). Two related code paths handle the prefix differently; any consumer of `geoWikiAnchor` has to know which kind it is by inspecting the first character.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:101-107, :311-316`

## [SUSPECT] SpanExtractor cannot distinguish a real wikilink with no target from a stale attribute (REJECTED: real but low-impact — the fallback produces a wikilink whose target is the visible text, which is the best guess from incomplete state. Hardening the contract belongs in the attribute-producer side, not the extractor.)
**Repro:** Styled storage with `geoWikiLink == true` but `geoWikiTarget` missing.
**Expected:** Either always carry a target or reject the attribute.
**Actual:** `SpanExtractor` falls back to the legacy `.wikiLink` case which round-trips via marker `[[...]]` only — the visible text in the storage becomes the wikilink target on serialize. If the visible text was an alias, the alias becomes the page name on the next round-trip.
**Where:** `Shared/DesignSystem/Editor/InlineFormat.swift:514-521`

