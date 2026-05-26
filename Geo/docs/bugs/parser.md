# Parser & round-trip bugs

## [LOSSY] Frontmatter split silently drops `\r` from CRLF files
**Repro:** Load any markdown with CRLF endings and a YAML frontmatter, e.g. `"---\r\nfoo: 1\r\n---\r\nhello\r\n"`.
**Expected:** `serialize()` returns the input verbatim (or at least keeps `\r` consistently on every line).
**Actual:** `splitFrontmatter` does `markdown.components(separatedBy: "\n")` then `lines.prefix(closeIndex + 1).joined(separator: "\n")`. Each preserved frontmatter line still has a trailing `\r` (it was never split on that), but the joins use only `\n`, so the rejoined frontmatter is `"---\r\nfoo: 1\r\n---\n"` — half the line endings flipped. The body half then also loses its CRs after the next `joined(separator: "\n")`. `BlockEditorDocument.serialize()` concatenates `hiddenFrontmatter + blocks.rawText`, so the file goes from CRLF to mixed/LF on every save.
**Where:** `Shared/DesignSystem/Editor/BlockEditorDocument.swift:46-73`
**Test:** `Tests/MarkdownStressTests.swift::testFrontmatterCRLFRoundTrip`

## [LOSSY] Frontmatter split fabricates a trailing newline
**Repro:** Document `"---\n---"` (no trailing newline at all).
**Expected:** Round-trip preserves byte-for-byte: `serialize()` == input.
**Actual:** `splitFrontmatter` returns `frontmatter = "---\n---\n"` because of the unconditional `+ "\n"` on line 71. The body is empty. `serialize()` returns `"---\n---\n"` — one byte longer than the input.
**Where:** `BlockEditorDocument.swift:71`
**Test:** `Tests/MarkdownStressTests.swift::testFrontmatterFabricatesNewline`

## [WRONG] `stripLegacySymphonyBodyMetadata` deletes ANY user line that starts with `State:`
**Repro:** Body contains a paragraph like `State: California\nPopulation: 39M\n`.
**Expected:** User content preserved.
**Actual:** The filter is applied to every line of the body regardless of context — the regex isn't anchored to legacy Symphony notes. Any line whose trimmed value starts with `State:` is silently dropped on load. Round-trip is destructive.
**Where:** `BlockEditorDocument.swift:76-86`
**Test:** `Tests/MarkdownStressTests.swift::testStateLinesAreDestroyed`

## [WRONG] `stripLegacySymphonyBodyMetadata` collapses `\n\n\n` → `\n\n` in arbitrary content
**Repro:** Code block containing three blank lines, or a paragraph block separator chain `"a\n\n\n\nb"`.
**Expected:** Whitespace inside content is preserved on round-trip.
**Actual:** Line 85 runs `replacingOccurrences(of: "\n\n\n", with: "\n\n")` over the entire body string including inside fenced code blocks. Multi-blank-line code or intentional spacing collapses.
**Where:** `BlockEditorDocument.swift:85`
**Test:** `Tests/MarkdownStressTests.swift::testTripleNewlineCollapsedInsideCodeBlock`

## [LOSSY] Unknown callout types are silently coerced to `note` on edit
**Repro:** Document `"> [!foobar] Title\n> body\n"`. Edit the callout body once (calls `withCalloutContent`).
**Expected:** Round-trip preserves `[!foobar]` (parser already round-trips rawText untouched on the read path; the edit path should not destroy unknown types).
**Actual:** `MarkdownBlockParser.parse` sets `CalloutType(rawValue: typeStr) ?? .note`. Initial round-trip via raw text is fine. But once the user edits the callout, `withCalloutContent` rebuilds the header from `kind` using `"> [!\(type.rawValue)]"` — `type` is now `.note`, so the unknown type vanishes.
**Where:** `MarkdownBlockParser.swift:167`, `EditorBlock.swift:155-165`
**Test:** `Tests/MarkdownStressTests.swift::testUnknownCalloutTypeLostOnEdit`

## [LOSSY] Toggle round-trip after edit drops space after `>>`
**Repro:** Author writes `">> [v] Daily plan\n>> body\n"` (Obsidian-style toggle with space between `>>` and `[v]`). Edit body once.
**Expected:** Stylistic spacing preserved.
**Actual:** `toggleRegex` accepts both `>>[v]` and `>> [v]` (`^>>\s*\[`). `withToggleContent` always emits `">>[\(marker)] \(title)\n"` — no space between `>>` and `[`. Diff churn on every edit. Same for `withToggleState` which uses `replacingOccurrences(of: ">>[\(old)]", with: ">>[\(new)]")` — fails to swap if the original markdown was `>> [v]` (with a space) because the search string never matches.
**Where:** `EditorBlock.swift:200-212, 214-222`
**Test:** `Tests/MarkdownStressTests.swift::testToggleStateSwapFailsWithSpacedSyntax`

## [WRONG] Nested fenced code blocks are split mid-fence
**Repro:**
```
````md
```swift
inner
```
````
```
That is: a 4-backtick fence containing a 3-backtick fence (a documented pattern in markdown-of-markdown).
**Expected:** Single code block with the inner backticks preserved verbatim.
**Actual:** `trimmed.hasPrefix("```")` triggers on the inner 3-backtick fence and closes the outer block, then opens a new code block, etc. Parser emits 2–3 separate code blocks. Lossy on serialize (some block kinds may swap), and the captured `codeBlockLanguage` is whichever appears on the inner fence.
**Where:** `MarkdownBlockParser.swift:97-115`
**Test:** `Tests/MarkdownStressTests.swift::testNestedFencedCodeBlockSplits`

## [LOSSY] Code-block language tag with trailing whitespace gets dropped on edit
**Repro:** `"```swift   \nx\n```\n"` (trailing spaces after language).
**Expected:** Round-trip preserves the raw header.
**Actual:** Initial parse round-trips via rawText. Once edited via `withCodeContent`, opener is rebuilt as `"```swift\n"` — trailing spaces gone. Minor, but predictable churn.
**Where:** `EditorBlock.swift:259-267`
**Test:** `Tests/MarkdownStressTests.swift::testCodeFenceTrailingSpaceLost`

## [WRONG] Paragraphs that happen to start and end with `|` become a table
**Repro:** A paragraph block whose single line is `"|im paranoid|"` (e.g., chat lingo, ASCII art).
**Expected:** Paragraph (it's not actually a table — there's no separator row).
**Actual:** `isTableLine = trimmed.hasPrefix("|") && trimmed.hasSuffix("|")` — that one line becomes a `.table` block with no separator row. Subsequent edits via the table block UI may not handle the malformed structure.
**Where:** `MarkdownBlockParser.swift:122-131`
**Test:** `Tests/MarkdownStressTests.swift::testSingleBarLineBecomesTable`

## (REJECTED: no external readers of sourceRange.location — internal usage is offset-relative and self-consistent post-renumber) [SUSPECT] `renumberOrderedRuns` adjusts `sourceRange.length` and `contentRange.location` but not `prefix`-derived caches
**Repro:** Parse `"3. first\n7. second\n"`, then `renumberOrderedRuns(&blocks)`.
**Expected:** All cached fields (`prefix`, `rawText`, `contentRange`, `sourceRange`) remain mutually consistent.
**Actual:** Math is internally consistent (content getter goes through `cleanContent` when present, which is fine). But the algorithm only touches *this* block's rawText/prefix/ranges — it does NOT shift the `sourceRange.location` of any *subsequent* block. After a multi-digit shrink (e.g. `10. → 1.`, delta=-1) all later blocks still have stale `sourceRange.location` values pointing into the old document. Anything that walks `blocks` and uses those locations to index back into a shared text storage (e.g. selection restoration) will be off-by-N.
**Where:** `MarkdownBlockParser.swift:410-445`

## [WRONG] `assignDepths` clamps bullet depth using the previous block — even when the previous block is a paragraph
**Repro:** `"Some paragraph\n    - deeply indented bullet\n"`.
**Expected:** Bullet keeps its indent-derived depth (2 from 4 spaces).
**Actual:** `maxAllowed = blocks[i - 1].depth + 1`. If prev is a paragraph, its depth is 0, so the bullet is clamped to depth 1 regardless of how deep the user indented. On serialize the rawText is unchanged (good), but `depth` is used by `BlockTreeNavigator.subtreeRange`, `visibleBlocks`, collapse logic, and the outline panel — the tree is mis-shaped.
**Where:** `MarkdownBlockParser.swift:245-263`
**Test:** `Tests/MarkdownStressTests.swift::testBulletDepthClampedByPrecedingParagraph`

## [LOSSY] `mergeIdentity` swaps IDs of identical-content blocks based on position, not user intent
**Repro:** Doc A has two empty paragraphs, the second has been collapsed. User inserts a heading between them. Doc B has [empty (collapsed), heading, empty]. Reparse + merge.
**Expected:** The pre-existing collapsed empty keeps its UUID and `collapsed: true` state.
**Actual:** The exact-match phase iterates new blocks in order and grabs the *first unconsumed* old block with matching `rawText`. For two identical empties, the new index 0 grabs old index 0 (uncollapsed) and the new last empty grabs old index 1 (collapsed) — so the collapsed flag travels to the wrong block. The same defect drifts identity whenever duplicated lines (`""`, `"---"`, `"> "`, etc.) shift position.
**Where:** `MarkdownBlockParser.swift:357-367`
**Test:** `Tests/MarkdownStressTests.swift::testMergeIdentityDriftsOnDuplicateContent`

## (REJECTED: fixed as side effect of byte-preserving splitFrontmatter rewrite — frontmatter now requires line 1 == "---") [SUSPECT] Frontmatter parser does not require frontmatter to start at line 1
**Repro:** `"\n\n---\nfoo: 1\n---\nbody\n"`.
**Expected:** This is NOT YAML frontmatter (must be at top of file per CommonMark/YAML convention).
**Actual:** Lines 49-51 skip leading blank lines, so a frontmatter buried after blank lines is honored. Probably benign but it lets a stray `---\n---\n` near the top "swallow" user content into the hidden frontmatter zone. Worth pinning.
**Where:** `BlockEditorDocument.swift:48-55`

## (REJECTED: round-trip preserved via paragraph fallback; existing test pins behavior; fixing the regex would risk false-positive image conversions) [SUSPECT] Image regex tolerates trailing whitespace but parens in URL break it
**Repro:** `"![alt](path with (parens).png)\n"`.
**Expected:** Either a clean image block or a clean paragraph fallback; not a half-parsed image.
**Actual:** `imageRegex = ^!\[([^\]]*)\]\(([^)]+)\)\s*$` — the `[^)]+` URL group stops at the first `)`. The trailing `).png)` then fails to satisfy the `\)\s*$` anchor, so the whole regex fails and the line falls through to paragraph. Round-trip is preserved (good), but it means image rendering is silently disabled for any URL with parens. Same issue applies to URL-encoded characters that include `)` (rare) and to filenames with `)`.
**Where:** `MarkdownBlockParser.swift:33-35`
**Test:** `Tests/MarkdownStressTests.swift::testImageUrlWithParensFallsBackToParagraph`

## (REJECTED: read-path is lossless via rawText; only the user's next edit closes the fence, which is the natural "complete what they started" behavior) [SUSPECT] Unclosed math/code/table at EOF gets silently closed
**Repro:** `"$$\nx^2\n"` (no closing `$$`) or `"```swift\ncode\n"` (no closing fence).
**Expected:** Either treat as malformed (paragraph) or surface to the user.
**Actual:** Lines 198-226 emit a math/code/table block stretching to end-of-file with the missing terminator. On the next user edit through `withCodeContent`/`withMathContent`, a closing fence is added — the file silently mutates. Detectable but may surprise users mid-typing.
**Where:** `MarkdownBlockParser.swift:198-226`

## [SUSPECT] `mergeIdentity` is O(N·M) on documents (exact-match phase scans every old block per new block)
**Repro:** Large note (10k+ blocks).
**Expected:** Linear with a hash index.
**Actual:** Lines 357-367 inner `for j in 0..<old.blocks.count` is hit for every `i`, with a linear `consumed.contains(j)` check. On a 10k-block document with mostly unique content the merge runs in tens of millions of comparisons per load. Not a correctness bug, but it's a foot-gun for the legacy "rewrite from disk" hot path.
**Where:** `MarkdownBlockParser.swift:353-367`
