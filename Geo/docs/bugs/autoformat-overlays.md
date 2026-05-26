# Auto-format, overlays, outline, anchor bugs

Stress-test of `BlockPrefixDetector`, `AutoFormatEngine`, `SlashCommandOverlay`, `MentionOverlay`, `OutlinePopover`, `PendingAnchorStore`, and the cmd+K link template in `TextViewKeyHandler`. The test target hits the surfaces that are reachable without an NSTextView; findings that require an interactive view are tagged "code inspection".

Severity ladder: CRASH > WRONG > LOSSY > MINOR > SUSPECT.

---

## [LOSSY] Tab-indented prefix never auto-formats

**Repro:** Type `\t# ` (tab, hash, space) into a paragraph block.
**Expected:** Either (a) treated as a heading (markdown allows up to 3 leading spaces before a heading marker, and tabs are usually equivalent), or (b) explicit no-op with a known reason. Today the user gets an ambiguous half-state — the leading whitespace makes the block look like indented text, not a heading, but markdown serialization will round-trip it as plain text because Geo's heading conversion never fires.
**Actual:** Returns `nil`. `BlockPrefixDetector.detect("\t# ")` and `detect(" # ")` both fall through every literal branch because the strings include the leading whitespace.
**Where:** `Shared/DesignSystem/Editor/BlockPrefixDetector.swift:13` — every check is an exact `==` against canonical strings, no `trimmingCharacters` or `hasPrefix` walk.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testPrefix_leadingTabHashSpace_returnsNil_inspect`

---

## [SUSPECT] `0. ` converts to an ordered list starting at item zero

**Repro:** Type `0. ` at the start of a paragraph.
**Expected:** Either reject `0` (lists in CommonMark / GFM are conventionally 1-indexed; rendered output for `0.` is "1." in most renderers because they use the first marker as a base) or normalize to `1.`. Geo stores the literal `0` as the start number.
**Actual:** `BlockPrefixDetector.detect("0. ")` returns `.convert(kind: .orderedItem(number: 0), …)`. The block is now an ordered item with `number: 0`. Markdown serialization will emit `0. content` which most external readers will silently renumber, so what the user sees in Geo's editor diverges from what GitHub/Obsidian/etc. render.
**Where:** `Shared/DesignSystem/Editor/BlockPrefixDetector.swift:28-33` — `Int(numPart)` accepts `0` and any non-negative integer without a floor check.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testPrefix_zeroDotSpace_convertsToOrderedZero`

---

## [SUSPECT] Negative-looking ordered list (`-1. `) silently rejected, but `+1. ` is also rejected

**Repro:** Type `+1. ` (plus-prefixed positive integer) at start of paragraph.
**Expected:** Either treat as `1.` ordered item, or reject; consistency with the `-`/`+`/`*` bullet markers where `+ ` works.
**Actual:** Inconsistent. `Int("+1")` returns `1` in Swift, so `+1. ` (4 chars before space) currently parses to `.orderedItem(number: 1)`. `Int("-1")` returns `-1`, so `-1. ` parses to `.orderedItem(number: -1)` — a negative-numbered list item. Both are accepted silently with no caller validation.
**Where:** `Shared/DesignSystem/Editor/BlockPrefixDetector.swift:30` — `Int(numPart)` accepts signed literals.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testPrefix_signedOrdered_acceptsPlusAndMinus`

---

## [WRONG] `1. ` typed back-to-back in the same block re-converts an already-converted block

**Repro:** In a paragraph, type `1. ` → block becomes ordered item (cleared content). Now type `2. ` immediately. Because the block content after the first conversion is `""`, the router strips the prefix and re-arms. But after the kind change from paragraph→orderedItem, the router's `handleContentChange` no longer routes through `BlockPrefixDetector.detect` at all — it goes through the per-kind branch. So the second `2. ` lands as the literal content "2. " of an `.orderedItem(number: 1)`. The visible list now reads `1. 2. ` even though the user thinks they're starting item 2.
**Expected:** Either consume `2. ` as a new list item (insert below) or ignore the keystrokes; "drop into raw content of the existing list item" is the worst outcome.
**Actual:** Code inspection — `BlockEventRouter.swift:178` `BlockPrefixDetector.detect(content)` only runs for `.paragraph` kind via the branch above it; after the first conversion, content edits flow through `document.updateBlockContent(at:content:spans:)` and the prefix is treated as literal text.
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:142-208` — auto-format is gated to paragraphs.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testPrefix_orderedItemDoesNotReConvert_inspect`

---

## [WRONG] AutoFormat single-star italic eats the wrong span on `*a**b*`

**Repro:** Cursor at end after typing `*a**b*`.
**Expected:** Ambiguous; user probably wanted bold-italic or "a" italic + "b" bold. Either no conversion or a deterministic, documented split.
**Actual:** `AutoFormatEngine.findInlinePattern(marker: "**", ...)` runs first and finds the open `**` at position 2 and close `**`… wait, there's only one `**` (between `a` and `b`). Re-examine: text is `*a**b*` (length 6). Cursor 6. `findInlinePattern("**", 6, …)` checks chars 4..6 == `b*` — no. So `**` pattern fails. Then `findSingleStarPattern(6, …)`: closeStart = 5, char 5 is `*`. Char 4 is `b` (not `*`), char 6 OOB → ok. Scan backwards for another `*` that isn't part of `**`. pos=4 (`b`) no. pos=3 (`*`): check pos-1 (pos=2) is `*` → `pos -= 1; continue` → pos=2 (`*`): check pos-1 (pos=1) is `a` → not `*`. So opener at pos=2. Content range is chars 3..5 = `*b`. The engine deletes openers at pos 2 and 5 and italicizes `*b` (containing a literal `*`). Result: visible italic-styled `*b` with a dangling `*` at position 0 and the `a` plain. That's almost certainly not what the user typed.
**Where:** `Shared/DesignSystem/Editor/AutoFormatEngine.swift:78-103` — the single-star scanner skips `**`-prefixed positions but doesn't ensure the matched opener isn't immediately followed by another `*`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testAutoFormat_mixedAsterisks_pickWrongOpener`

---

## [LOSSY] AutoFormat 200-char scan limit truncates legitimate bold at long lines

**Repro:** Type a line longer than 200 characters with `**word**` at the very end where the opening `**` is more than 200 chars before the closing `**`.
**Expected:** Bold applied (the user clearly intended a pair).
**Actual:** `AutoFormatEngine.findInlinePattern` and `findSingleStarPattern` both cap the scan at `closeStart - 200`. Beyond 200 chars the opener is invisible to the matcher; the user's `**…**` remains as literal stars.
**Where:** `Shared/DesignSystem/Editor/AutoFormatEngine.swift:58`, `:86`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testAutoFormat_bold_over200CharsAway_doesNotMatch`

---

## [WRONG] `BlockNSTextView.deleteBackward` dismisses mention even when there's still a `[[` earlier in the block (REJECTED: lives in `BlockNSTextView.swift` — other agent's lane)

**Repro:** In a block containing `[[Notes]] then [[A`, with the caret in the trailing `[[A`, hit backspace until you delete the last `[[` of the second mention. The check `string.contains("[[")` still passes because the first `[[Notes]]` is there. Now delete one more char and you've dismissed the mention as expected. But: in `[[A]] then [[B`, with caret in `[[B`, the same logic keeps the mention open while only `[[A]]` remains — because `string.contains("[[")` is still true even though there is no open `[[` to the left of the caret. The overlay should be dismissed (caret is now in plain text), but it persists.
**Expected:** Dismiss when there is no unclosed `[[` to the left of the caret.
**Actual:** Code inspection — `BlockNSTextView.swift:706-709`: `if isMentionMode && !string.contains("[[") { … dismiss }` ignores caret position entirely; any `[[` anywhere in the block (including a fully closed `[[X]]`) keeps the overlay alive.
**Where:** `Shared/DesignSystem/Editor/BlockNSTextView.swift:706`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testMention_dismissCheckIgnoresCaretPosition_inspect`

---

## [WRONG] Mention overlay reactivation: `flushContentChange` only re-arms `mentionMode` from off→on; if the user closes a `[[X]]` and starts a new `[[`, the new one may not open (REJECTED: lives in `BlockNSTextView.swift` debounce/`updateSlashAndMentionState` — other agent's lane)

**Repro:** Inside a paragraph that already contains `[[Done]]`, the user types ` then [[B`. After the `[[`, expectation: mention overlay opens for "B".
**Expected:** Overlay opens with filter "B".
**Actual:** Path in `updateSlashAndMentionState` (BlockNSTextView.swift:189-213):
- `isMentionMode == false`. `beforeCursor.range(of: "[[", options: .backwards)` finds the *latest* `[[` (good). `afterOpen = "B"`, no `]]`. So `isMentionMode = true; mentionActivated("B")`. So it does open. Good.
- Now the user types `]` then `]` — afterOpen = "B]]", contains "]]" → `mentionDismissed`. Good.
- Now the user types ` then [[C`. Cursor moves; `beforeCursor.range(of: "[[", options: .backwards)` finds the latest `[[` (good); afterOpen = "C", no "]]". Activates again. **But** the `flushContentChange` is only called when the user types a literal space (insertText path) or on the 50 ms timer. If the user is typing quickly into the second mention and pauses for ≥ 50 ms only after the `[[`, the overlay opens. If the user blasts through it without pause, the overlay only opens once the next debounce tick fires.
**Where:** Latency-only — `BlockNSTextView.swift:131-156` debouncing. Not a correctness bug per se but the overlay can appear 50 ms after the keystrokes, which feels laggy on slower main threads.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testMentionFiltered_emptyState`

---

## [MINOR] Mention filter normalization mismatch: `filtered(...)` uses `contains` but slash filter uses `hasPrefix` (FIXED: slash now uses `contains` for label/id/aliases; mention already uses `contains`. Both overlays now share substring semantic.)

**Repro:** Type `[[bo` to filter for "Bold heading"; type `/bo` to filter slash commands.
**Expected:** Same matching semantics or documented difference.
**Actual:** `MentionOverlay.filtered` does `title.lowercased().contains(query)` (substring, anywhere in title). `SlashCommandOverlay.filtered` does `label.contains(query)` for the label but `hasPrefix(query)` for `id` and `aliases`. So slash for `/list` matches the "Bullet List" alias `list` (prefix) but for `/llist` matches nothing — even though a mention with title "List of pages" with filter "list" matches by contains. The asymmetry is a small UX surprise.
**Where:** `Shared/DesignSystem/Editor/SlashCommandOverlay.swift:101-105` vs `MentionOverlay.swift:37-42`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testSlashVsMention_filterSemanticsDiffer`

---

## [WRONG] Anchor focus: case-insensitive but not diacritic-insensitive (FIXED: `BlockEditorView.normalizeHeading` now folds diacritics + lowercases. Covered by `testHeadingMatch_diacriticsNormalized`.)

**Repro:** Click a wikilink `[[Page#café]]` where the heading in the target document is `## Café`.
**Expected:** Anchor matches (most note apps normalize unicode for anchor lookup).
**Actual:** `headingMatch` does only `lowercased()` + whitespace trim. `"café".lowercased()` is `"café"` (lowercase). `"Café".lowercased()` is `"café"`. They DO match in this exact case (lowercasing preserves the accent). But: `[[Page#cafe]]` (no diacritic) vs `## Café` will NOT match because `lowercased()` does not strip diacritics. Markdown anchors in Pandoc/GitHub strip diacritics; Geo's matcher does not.
**Where:** `Features/Blocks/UI/BlockEditor.swift:688-701` — only `trimmingCharacters` + `lowercased`. No `applyingTransform(.stripDiacritics, …)`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testHeadingMatch_diacriticsNotNormalized_inspect`

---

## [WRONG] Anchor focus: heading text with inline markdown only matches if stripped, but `[[Page#**Bold**]]` won't match `## **Bold**` (FIXED: `BlockEditorView.stripInlineMarkdown` strips `*`, `**`, `***`, `_`, `__`, `` ` ``, `~~` from both anchor and heading before comparison. Covered by `testHeadingMatch_anchorWithMarkdown_matchesAfterStrip` + `testStripInlineMarkdown_handlesAllMarkers`.)

**Repro:** Heading `## **Bold** title`. Click `[[Page#**Bold** title]]` (anchor includes the stars).
**Expected:** Match (the anchor refers to the visible text and the user copied the markdown literally).
**Actual:** `headingMatch` reads `block.cleanContent ?? block.content`. `cleanContent` is the stripped form ("Bold title"). The incoming anchor "**Bold** title" still has the stars, so the normalized lowercase compare `"**bold** title" == "bold title"` fails. The user gets no focus.
**Where:** `Features/Blocks/UI/BlockEditor.swift:688-701`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testHeadingMatch_anchorWithMarkdown_doesNotMatch`

---

## [LOSSY] PendingAnchorStore drops earlier anchor when same blockId clicked twice quickly (FIXED: `pending` is now `[String: [String]]` FIFO queue. `consume` returns the oldest pending anchor. Covered by `testPendingAnchor_overwriteSemantics`.)

**Repro:** Click `[[Page#Intro]]` then quickly click `[[Page#Setup]]` before the editor for `Page` has appeared and consumed.
**Expected:** Probably honor the latest (current behavior) or queue both (debatable). Either way, the user should not get the earlier anchor.
**Actual:** `PendingAnchorStore.enqueue` is a flat `[String: String]`. `enqueue("page", "Intro")` then `enqueue("page", "Setup")` → only "Setup" remains, "Intro" silently lost. That happens to be the right pick here, but if the user clicked them in reverse order the latest write wins. Either way it's an opinionated overwrite with no signaling to the caller.
**Where:** `Shared/DesignSystem/Editor/PendingAnchorStore.swift:9-11`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testPendingAnchor_overwriteSemantics`

---

## [LOSSY] PendingAnchorStore: anchor for a target window that is already open is never consumed (FIXED: `enqueue` posts `Notification.Name.geoPendingAnchorChanged` with the blockId as object; `BlockEditorView.body` adds `.onReceive` for it and calls `consumePendingAnchor()` which updates `document.focusRequest`. Covered by `testPendingAnchor_enqueuePostsNotification`.)

**Repro:** Page document is already open. User clicks `[[Page#Conclusion]]` from another window. `openWindow(value: match.id)` no-ops (existing window comes forward) but the existing `BlockEditorView` already called `loadContent` long ago and set `hasLoadedContent = true`. The new anchor sits in `PendingAnchorStore` forever (until next consume).
**Expected:** The existing editor view subscribes to `PendingAnchorStore` and scrolls when a new anchor arrives; today it doesn't.
**Actual:** Code inspection — `BlockEditor.swift:665-686` consumes the anchor only inside `loadContent`, which is guarded by `hasLoadedContent`. No observation of `PendingAnchorStore.shared.$pending`.
**Where:** `Features/Blocks/UI/BlockEditor.swift:665-686`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testPendingAnchor_alreadyOpenWindow_inspect`

---

## [MINOR] OutlineExtractor produces a fresh UUID for every heading on every call → SwiftUI ForEach can over-rebuild rows (FIXED: `OutlineHeading.id` is now a computed property returning `blockId`. No more per-call UUID minting. Covered by `testOutlineExtractor_idsAreStableAcrossCalls`.)

**Repro:** Open OutlinePopover, scroll, the popover redraws.
**Expected:** Stable IDs per heading so SwiftUI diffing is cheap.
**Actual:** `OutlineExtractor.headings(from:)` allocates `OutlineHeading(id: UUID(), …)` per call. Every recomputation produces brand-new IDs; `ForEach(headings)` sees an entirely new list and tears down every row.
**Where:** `Features/Blocks/UI/OutlinePopover.swift:79-86`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testOutlineExtractor_idsAreUnstableAcrossCalls`

---

## [MINOR] OutlinePopover indent: depth-6 heading indents 60 pt; on the 260-pt-wide popover the title gets clipped (FIXED: `OutlinePopover.leadingPad(forLevel:)` clamps the indent level to 4, capping leading padding at 48 pt regardless of heading depth. Covered by `testOutline_depthSixIndent_isClampedAtLevel4`.)

**Repro:** Document with `###### Six` heading; open outline.
**Expected:** Indentation clamps so the label remains legible.
**Actual:** `padding(.leading, 12 + CGFloat(heading.level - 1) * 12)` = `12 + 5*12 = 72`. The popover frame is 260 pt; trailing padding 12; lineLimit(1) → title truncates aggressively. Visually fine for short titles, bad for any heading text > ~25 chars at depth 6.
**Where:** `Features/Blocks/UI/OutlinePopover.swift:49`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testOutline_depthSixIndent_isComputedAt72pt`

---

## [WRONG] cmd+K with no selection produces `[]()` then cursor jumps to inside `[]` — but a subsequent typing of `Foo` lands between `[` and `]`, NOT between `]` and `(`. Then arrows escape to text-edit normally. If the user expects to type the URL first (per most editors), they end up typing the link text. Minor UX, but the cursor position is misleading because the URL is more often filled in second.

**Repro:** Empty caret, press cmd+K, then type `https://example.com`.
**Expected:** Either parens already filled (caret in `()`) so URL appears in URL position, or label position. Either is defensible, but pick one and document it. Geo currently places caret at offset `+1` from where `[]()` was inserted — i.e. between `[` and `]`. The user typing a URL gets `[https://example.com]()` (URL becomes label, label position has no URL).
**Actual:** `TextViewKeyHandler.swift:74-78`: `let cursorPos = sel.location + 1` → between `[` and `]`. No assistive placeholder text either.
**Where:** `Shared/DesignSystem/Editor/TextViewKeyHandler.swift:65-79`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testCmdK_emptyCursor_inspect`

---

## [LOSSY] cmd+K with selection inside a wikilink corrupts the link

**Repro:** Block contains `[[Some Page]]`. Select the substring `Some Page` (just the visible text inside the double brackets). Press cmd+K.
**Expected:** Skip the replacement, or warn, or wrap-around without breaking the wikilink.
**Actual:** `insertLinkTemplate` does `(textView.string as NSString).substring(with: sel)` then inserts `[Some Page]()` over the selection. Result on disk: `[[Some Page]()]` — invalid markdown that breaks both the wikilink and the new link target.
**Where:** `Shared/DesignSystem/Editor/TextViewKeyHandler.swift:65-72`.
**Test:** `Tests/AutoFormatAndOverlaysStressTests.swift::testCmdK_selectionInsideWikilink_corruptsLink_inspect`

---

## Summary

15 findings. Severity distribution:
- WRONG: 6 (auto-format `*a**b*`, ordered re-convert, mention dismiss caret-ignorance, anchor diacritics, anchor markdown, cmd+K empty cursor placement)
- LOSSY: 4 (tab-indented prefix, 200-char scan limit, PendingAnchor overwrite, cmd+K wikilink corruption)
- MINOR: 3 (slash/mention filter asymmetry, outline ID instability, depth-6 indent)
- SUSPECT: 2 (`0.` ordered start, signed-integer ordered prefixes)

The cluster around `headingMatch` (diacritics + markdown in anchors) is the highest-leverage fix area for users that maintain hand-crafted `[[Page#anchor]]` graphs.
