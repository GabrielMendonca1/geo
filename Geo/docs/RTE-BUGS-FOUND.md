# RTE bugs — 2026-05-11 stress sweep & fix pass

Output of a 5-agent parallel stress sweep over parsing, inline format, edit ops, attachments, and auto-format/overlays, **followed by a 5-agent parallel fix pass**. All confirmed bugs are now fixed; the slice files in `docs/bugs/` carry per-bug status (`FIXED`, `REJECTED: <reason>`, or `DEFERRED: <reason>`).

## Final status

- **365 tests pass, 0 fail.** Sweep covers 10 suites (5 new stress suites + 5 pre-existing).
- **40 of the 40 confirmed bugs fixed** (25 failing tests + 15 attachment document-style passes flipped to assert correct behavior).
- **One regression caught and fixed mid-pass**: Agent 1's table heuristic (`pipeCount >= 3`) over-rejected legitimate single-column tables (`| A |\n| --- |\n...`). New heuristic accepts a single-pipe line ONLY when the next line is a separator row (`| --- |`), OR when the line itself has 3+ pipes (multi-cell). Both `BlockModelTests.testParseTableSingleLine` (multi-cell) and `BlockModelTests.testTableFollowedByParagraph` (single-cell with separator) plus `MarkdownStressTests.testSingleBarLineBecomesTable` (`|im paranoid|` — paragraph) now all pass.
- **3 production files restored** that had been deleted from disk but still referenced by pbxproj: `Commands/InsertBlockCommand.swift`, `BlockSerializer.swift`, `StaticBlockView.swift`. They were checked out from `1a953252`.
- **DEFERRED items** (the big-but-pragmatic ones): dual undo stacks unification, auto-format invisible to canonical undo stack, code-fence multi-line edits — see slice files for rationale.

## What was fixed, by slice

### Parser & round-trip — [docs/bugs/parser.md](bugs/parser.md)
9 confirmed bugs → all FIXED. SUSPECTs evaluated: 5 REJECTED with rationale (regex stale locations, frontmatter line-1 requirement, image-paren tolerance, EOF math/code completion, identity drift on duplicates). One perf win: `mergeIdentity` rebuilt as O(N+M) using a `[rawText: [oldIndex]]` index.

Key root-cause fixes:
- `stripLegacySymphonyBodyMetadata` gated behind `markdown.contains("[[Symphony]] #symphony")` — no longer mutates arbitrary user content (was deleting `State:` lines, collapsing `\n\n\n` in code blocks).
- Nested fenced code blocks now track opener length and require closers with equal-or-greater fence length.
- Single-bar paragraphs only become tables with multi-cell signal or a separator on next line.
- Unknown callout types preserved verbatim via raw-header re-use in `EditorBlock.withCalloutContent`.
- Toggle spaced syntax `>> [v]` round-trips correctly.
- Frontmatter `splitFrontmatter` no longer fabricates trailing newlines.
- Code fence trailing whitespace preserved.
- `assignDepths` only clamps bullet depth when previous block is itself a list.

### Inline format — [docs/bugs/inline-format.md](bugs/inline-format.md)
12 confirmed bugs → all FIXED. Plus 2 SUSPECTs confirmed and fixed (multi-line wikilink, multi-line math). 5 SUSPECTs REJECTED with rationale.

Key root-cause: **code-span detection now runs FIRST** and `isInsideCode` excludes ranges from all subsequent inline passes (wiki, math, link, bold, italic, strike, highlight, underscore-italic, tag). Single fix lit up `testWikiLinkInsideBackticksIsNotLiteral`, `testMathInsideBackticksIsNotMath`.

Other fixes:
- Math regex: forbid digit-bounded `$` (`(?<![\$0-9])` / `(?![\$0-9])`) — `$5 and $10` no longer becomes math.
- Link regex: escape lookbehind `(?<![\[\\])` and balanced inner-paren URL group.
- Wikilink: empty target `[[|alias]]` rejected; empty alias `[[Page|]]` rendered as full bracket form; whitespace-padded `[[ Page ]]` trims target.
- Tag regex: extended preceding-char class to include `,.;:!?/\\-–—[{`; tag matches excluded from link-text ranges.
- Underscore italics `_x_` added with intra-word guard (`foo_bar_baz` does not match).
- AutoFormatEngine `***foo***`: when `**` close pattern matches, if preceding char is `*`, shift `closeStart` left by 1 — correctly captures `bold` as content.

### Edit operations & cmd+K — [docs/bugs/edit-ops.md](bugs/edit-ops.md)
1 failing test + 1 cmd+K bug → all FIXED. 5 SUSPECTs confirmed and fixed. 12 SUSPECTs DEFERRED (mostly the dual-undo-stack ecosystem — needs dedicated slice). 6 SUSPECTs REJECTED with rationale.

Key fixes:
- Toggle → callout convert: toggle title becomes callout title, content preserved.
- Code block → paragraph convert: code body now copied to paragraph via `block.codeContent`.
- Merge bullet → heading: now blocked (kept separate) instead of swallowing bullet.
- Indent uses `hasListAncestor(of:in:)` — heading-then-bullet no longer treats heading as sibling; repeat-Tab keeps deepening until depth ancestor mismatch.
- cmd+K with selection inside `[[wikilink]]`: now a no-op via `rangeOverlapsWikilink(_:in:)` checking `.geoWikiLink` attribute. Test renamed `_corruptsLink_inspect` → `_isNoOp`.

### Attachments & paste/drag — [docs/bugs/attachments.md](bugs/attachments.md)
17 findings → 14 FIXED, 4 DEFERRED (CMYK encoding, symlink/`.webloc` semantics, block-renamed-mid-paste race, mid-word inline insertion intent). All 15 document-style tests rewritten to assert correct post-fix behavior.

Key security fixes:
- **Disk-name and markdown-link unified through single `sanitizeAttachmentFilename`** applied inside `copyAttachment` BEFORE the write. `..hack.png`, RTL-override chars (U+202A–202E, U+2066–2069), control chars (0x00-0x1F, 0x7F), and trailing whitespace all stripped from BOTH paths.
- `..` runs collapsed to `_` (with proper stem/extension preservation; `foo..tar.gz` no longer loses extension).
- Filename truncation: max 200 UTF-8 bytes, extension preserved.

Other fixes:
- File-URL image drops now route through `saveImage` so the 1920 px cap applies.
- PNG signature `89 50 4E 47 0D 0A 1A 0A` + min-size validation; truncated PNG bytes rejected.
- `uniqueURL` atomic via `O_EXCL` placeholder reservation — 32 concurrent calls produce 32 distinct paths.
- Snippet join `\n\n` (separate blocks) instead of `\n`.
- Alt-text escapes `\\`, `[`, `]`, `(`, `)`.
- Partial-failure drop: returns `false` only if ALL files fail, individual failures logged.
- Empty filename fallback is `attachment.bin`.

### Auto-format & overlays — [docs/bugs/autoformat-overlays.md](bugs/autoformat-overlays.md)
3 failing tests + 6 SUSPECTs confirmed and fixed. 2 SUSPECTs REJECTED (out-of-lane). Cmd+K SUSPECT was Agent 3's lane.

Key fixes:
- Slash + mention overlay filter unified: both use `contains` for label/id/aliases.
- `PendingAnchorStore` now a FIFO queue per blockId (`[String: [String]]`); multiple clicks for same target preserved in order; `enqueue` posts `Notification.Name.geoPendingAnchorChanged` so already-open editors can consume.
- Anchor focus: `headingMatch` folds diacritics (`.folding(options: .diacriticInsensitive)`) and strips inline markdown markers (`***`/`**`/`*`/`__`/`_`/`` ` ``/`~~`) from both anchor and heading before comparison.
- `OutlineExtractor.OutlineHeading.id` is now computed `var id: UUID { blockId }` — SwiftUI ForEach stable across re-renders.
- `OutlinePopover` indent clamps level to 4 (max 48 pt left padding) so depth-6 headings don't clip on the 260-pt popover.

## Reproducing

```bash
xcodebuild test -scheme Geo -destination 'platform=macOS' \
  -only-testing:GeoTests/MarkdownStressTests \
  -only-testing:GeoTests/InlineFormatStressTests \
  -only-testing:GeoTests/BlockEditOpsStressTests \
  -only-testing:GeoTests/AttachmentStressTests \
  -only-testing:GeoTests/AutoFormatAndOverlaysStressTests \
  -only-testing:GeoTests/BlockPrefixDetectorTests \
  -only-testing:GeoTests/BlockModelTests \
  -only-testing:GeoTests/BlockGraphServiceTests \
  -only-testing:GeoTests/MarkdownIndexingServiceTests \
  -only-testing:GeoTests/BlocksStoreCheckboxTests
```

Expected: `** TEST SUCCEEDED **`, 365 passed / 0 failed.

## What remains (DEFERRED, not done)

Tracked inline in slice files with rationale. Headline items:

### Still DEFERRED (require dedicated slices)

1. ~~**Dual undo stacks**~~ — FIXED 2026-05-11: `EditorCommandHistory` deleted; `BlockEditorDocument.executeCommand(_:undoManager:)` now registers via NSUndoManager using symmetric `applyExecute`/`applyUndo`. Single canonical stack.
2. ~~**Auto-format is invisible to canonical undo stack**~~ — FIXED via #1: structural edits already registered with NSUndoManager; with command stack unified, all edits flow through one stack.
3. ~~**Merge into rich blocks**~~ — FIXED 2026-05-11 batch: rejection branches in `mergeWithPrevious` now set focusRequest back to current block + bump editGeneration → text view rebinds from model.
4. ~~**Split truncation heuristic**~~ — FIXED 2026-05-11 batch: `BlockEditorEvent.split` carries explicit `cursorOffset`; router does NSString-indexed substring, no suffix matching.
5. ~~**Block-renamed-mid-paste**~~ — FIXED 2026-05-11 batch: `BlockEditor.swift` uses `liveBlock.url` (computed) inside the escaping `attachmentHandler` closure → paste resolves URL at call time.
6. **Math renderer parity with KaTeX** — Unicode-substitution-only. Plan written in [docs/MATH-RENDERER-PLAN.md](MATH-RENDERER-PLAN.md): recommendation is SwiftMath (pure-Swift SPM dep). Not yet implemented.
7. **moveBlockUp depth mismatch** — debatable; REJECTED in slice file pending UX decision.
8. ~~**Paste 100+ lines**~~ — FIXED 2026-05-11 batch: `pasteLineCap = 500` in `BlockEventRouter`. Excess lines dropped with `os.log` warning.

### Fixed during autonomous loop (5 iterations)

- ✅ **Split inside wikilink** (iter 1) — `BlockNSTextView.insertNewline` snaps caret to end of wikilink before split fires.
- ✅ **Slash/mention state persists across auto-format** (iter 2) — `handleContentChange` clears overlay state when `BlockPrefixDetector` outcome detected; `handleContentChange` made `mutating`.
- ✅ **CMYK / unusual color-space source images** (iter 3) — `bitmapRepresentation` requires `.deviceRGB`/`.calibratedRGB` for fast path; non-RGB falls through to drawing context which produces deviceRGB.
- ✅ **copySelectedBlocks ignores rich kinds** (iter 4) — uses `\.rawText` joined without separator, same path as `BlockSerializer.serialize`; fences, table pipes, callout markers preserved.
- ✅ **Mention state has no timeout / sanity reset** (iter 5) — `handleFocus` clears slash/mention state when focused blockId differs from state's blockId.

### Rejected during autonomous loop

- ❌ **Indent first / outdent zero silent no-ops** — NSBeep is too aggressive; silent no-op matches macOS norm (TextEdit/Notes/Obsidian). Real action item is "Tab inserts tab in non-list", which is a feature.
- ❌ **Block reorder cycle / upper-bound** — already had a bounds guard; cycle scenarios not reachable from event paths.

Use the `(DEFERRED: …)` markings in each slice file to plan the next sweep.

## Not covered by this sweep

- `HTMLToMarkdown.swift` — only smoke-tested for tables/nested formatting
- `FindReplaceBar.swift`
- `BacklinksPanel.swift`
- `EditorStatusBar.swift` regex strip on heavy real-world markdown
- Multi-window WindowChrome coordination
- `mergeIdentity` on large (>1MB) external file diffs
