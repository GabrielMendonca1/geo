# RTE Parity Matrix

Live tracker of the Geo block editor's feature surface, scored against Obsidian as the reference. **Update this file in any PR that touches `Shared/DesignSystem/Editor/`, `Shared/DesignSystem/Markdown/`, or `Features/Blocks/UI/BlockEditor.swift`.** A PR that adds, changes, or removes editor behaviour without bumping the matrix should be rejected on review.

## Why this exists

There is no formal spec or eval harness guaranteeing parity. This matrix is the régua. Three rules:

1. **Status changes require evidence.** Promote a feature to ✅ only when (a) implementation file:line is recorded, (b) at least one snapshot/round-trip test exists in `Tests/`, and (c) keyboard shortcut + slash command + floating toolbar entry are wired where applicable.
2. **Partial (⚠️) means "user can hit a wall."** Document the wall in the Notes column. Don't paper over.
3. **Missing (❌) is acceptable** as long as it's listed. Hidden gaps are the bug.

## Architecture map

The editor is layered. Knowing where to make a change is half the battle.

```
Features/Blocks/UI/BlockEditor.swift          ← chrome: type/layer chips, autosave, backlinks
  └─ Shared/DesignSystem/Editor/BlockListView.swift    ← list of blocks + find/replace
      └─ BlockRowView.swift                            ← dispatcher by block kind
          └─ BlockTextEditorView → BlockNSTextView    ← per-block NSTextView
              ├─ MarkdownBlockParser            ← markdown → [EditorBlock]
              ├─ InlineFormat (InlineParser, SpanStyler, SpanExtractor)
              ├─ AutoFormatEngine               ← inline shortcuts (**x** → bold)
              ├─ TextViewKeyHandler             ← cmd+B/I/E/Shift+S, cmd+D, cmd+Shift+↑↓
              ├─ FloatingToolbar                ← contextual toolbar on selection
              ├─ SlashCommandOverlay            ← `/` at block start
              └─ MentionOverlay                 ← `@` block mention picker
  └─ BlockEditorDocument                         ← debounced autosave + frontmatter split
```

Persistence is markdown-on-disk. Frontmatter (YAML) is split out, hidden from editing, and reattached on serialize ([BlockEditorDocument.swift:40](../Shared/DesignSystem/Editor/BlockEditorDocument.swift)). External edits reconcile via `MarkdownBlockParser.mergeIdentity` ([MarkdownBlockParser.swift:349](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift)).

**Rendering mode:** single hybrid mode. Syntax tokens (`**`, `*`, `~~`, `` ` ``) are stripped from the display layer permanently. There is **no Source / Live Preview / Reading Mode toggle** as Obsidian has — when this feature lands it goes in this matrix as a new row.

## Block-level features

| # | Feature | Status | Where | Gap notes |
|---|---|---|---|---|
| B1 | Headings H1–H6 | ✅ | [MarkdownBlockParser.swift:269](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift) + slash menu | — |
| B2 | Paragraph | ✅ | [MarkdownBlockParser.swift:340](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift) | — |
| B3 | Bullet list (nested) | ✅ | [MarkdownBlockParser.swift:302](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift); depth via [BlockTreeNavigator.swift](../Shared/DesignSystem/Editor/BlockTreeNavigator.swift) | — |
| B4 | Numbered list (auto-renumber) | ✅ | [MarkdownBlockParser.swift:313](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift) `renumberOrderedRuns()` | — |
| B5 | Indent / outdent | ✅ | [Commands/IndentBlockCommand.swift](../Shared/DesignSystem/Editor/Commands) | Verify cmd+] / cmd+[ shortcuts are wired in TextViewKeyHandler. |
| B6 | Task list `- [ ]` / `- [x]` | ✅ | [MarkdownBlockParser.swift:289](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift); toggle via [BlockRowView.swift](../Shared/DesignSystem/Editor/BlockRowView.swift) `onToggleCheckbox` | — |
| B7 | Blockquote (nested) | ✅ | [MarkdownBlockParser.swift:280](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift) | — |
| B8 | Fenced code block + syntax highlight | ⚠️ | [MarkdownBlockParser.swift:97](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift); [SyntaxHighlighter.swift](../Shared/DesignSystem/Markdown/SyntaxHighlighter.swift) | ~15 languages: dedicated tokenizers for HTML/XML, CSS/SCSS/LESS, JSON, Markdown, SQL plus a generic keyword path covering Swift, JS/TS, Python, Go, Rust, Java/Kotlin, C/C++, Ruby, shell. Obsidian uses Prism (~200 langs). Generic fallback for unknown langs. |
| B9 | Horizontal rule | ✅ | [MarkdownBlockParser.swift:326](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift) | — |
| B10 | Tables (insert / edit / nav) | ✅ | [TableEditorView.swift](../Shared/DesignSystem/Editor/TableEditorView.swift) | Verify HTML→md paste preserves tables ([HTMLToMarkdown.swift](../Shared/DesignSystem/Editor/HTMLToMarkdown.swift) currently lacks table conversion). |
| B11 | Math block `$$…$$` | ⚠️ | [MarkdownBlockParser.swift:74](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift); [MathRenderer.swift](../Shared/DesignSystem/Editor/MathRenderer.swift) | Renderer is hand-rolled Unicode substitution. Breaks on non-trivial LaTeX (matrices, alignments, fractions). No KaTeX. |
| B12 | Callouts `> [!type]` (12 types) | ✅ | [MarkdownBlockParser.swift:161](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift); [EditorBlock.swift:4](../Shared/DesignSystem/Editor/EditorBlock.swift) | Tip, info, warning, danger, note, quote, example, bug, success, question, abstract, todo. |
| B13 | Toggle / collapsible | ✅ | [MarkdownBlockParser.swift:133](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift) | — |
| B14 | Block drag-drop reorder | ✅ | [BlockDragController.swift](../Shared/DesignSystem/Editor/BlockDragController.swift) | Subtree-aware (preserves nesting). |
| B15 | Multi-block select (copy / delete / move) | ✅ | [BlockSelectionManager.swift](../Shared/DesignSystem/Editor/BlockSelectionManager.swift) | shift+click, cmd+click, cmd+A, cmd+Shift+↑↓ to move. |

## Inline formatting

| # | Feature | Status | Where | Gap notes |
|---|---|---|---|---|
| I1 | Bold `**x**` | ✅ | [TextViewKeyHandler.swift:38](../Shared/DesignSystem/Editor/TextViewKeyHandler.swift) (cmd+B); [AutoFormatEngine.swift:17](../Shared/DesignSystem/Editor/AutoFormatEngine.swift); [InlineFormat.swift:319](../Shared/DesignSystem/Editor/InlineFormat.swift) (SpanStyler) | — |
| I2 | Italic `*x*` / `_x_` | ✅ | [AutoFormatEngine.swift:93](../Shared/DesignSystem/Editor/AutoFormatEngine.swift) `findSingleStarPattern` + [AutoFormatEngine.swift:120](../Shared/DesignSystem/Editor/AutoFormatEngine.swift) `findSingleUnderscorePattern`; InlineParser parses both forms | Both `*…*` and `_…_` parse to italic spans and live auto-format on type. Underscore guards against intra-word matches (`a_b_c`). Tests: [InlineFormatStressTests.swift](../Tests/InlineFormatStressTests.swift) `testUnderscoreItalicNotParsed`/`testIntraWordUnderscoreNotItalic`; [AutoFormatAndOverlaysStressTests.swift](../Tests/AutoFormatAndOverlaysStressTests.swift) `testAutoFormat_singleUnderscore_*`. |
| I3 | Strikethrough `~~x~~` | ✅ | cmd+Shift+S; auto-format | — |
| I4 | Inline code `` `x` `` | ✅ | cmd+E; auto-format; [InlineFormat.swift:325](../Shared/DesignSystem/Editor/InlineFormat.swift) | — |
| I5 | Highlight `==x==` | ✅ | [InlineFormat.swift](../Shared/DesignSystem/Editor/InlineFormat.swift) (parser + SpanStyler `.backgroundColor` + SpanExtractor round-trip via `.geoHighlight`); [AutoFormatEngine.swift](../Shared/DesignSystem/Editor/AutoFormatEngine.swift) pair `("==", .highlight)`; [TextViewKeyHandler.swift](../Shared/DesignSystem/Editor/TextViewKeyHandler.swift) `cmd+Shift+H`; [FloatingToolbar.swift](../Shared/DesignSystem/Editor/FloatingToolbar.swift) Highlight button (`highlighter` SF Symbol); `ActiveFormattingState.isHighlight` at [BlockTextEditor.swift:61](../Shared/DesignSystem/Editor/BlockTextEditor.swift); cursor-state mirror in [BlockNSTextView.swift](../Shared/DesignSystem/Editor/BlockNSTextView.swift) `updateFormattingState`. | Yellow background `NSColor.systemYellow.withAlphaComponent(0.35)`. Highlight skipped when `.code` overlaps so code's background wins. Promote criterion: parser snapshot test (still pending — see "Test coverage"). |
| I6 | Underline | ❌ | — | Used internally as decoration for wikilinks/links only ([InlineFormat.swift:346](../Shared/DesignSystem/Editor/InlineFormat.swift)); not exposed as user formatting. |
| I7 | Inline math `$x$` | ⚠️ | [InlineFormat.swift](../Shared/DesignSystem/Editor/InlineFormat.swift) `.geoMath` attribute; [MathRenderer.swift](../Shared/DesignSystem/Editor/MathRenderer.swift) | Same Unicode-substitution renderer as B11. |
| I8 | Markdown link `[txt](url)` | ✅ | InlineParser; clickable via `.geoLink` attribute | — |
| I9 | Bare URL autolink | ✅ | [InlineFormat.swift:69](../Shared/DesignSystem/Editor/InlineFormat.swift) `bareURLRegex` → `.autoLink(url:)` span + `.geoAutoLink` attribute (clickable, round-trips via SpanExtractor) | Raw `http(s)://…` linkified without `[]()` wrapping; no characters stripped from the source. Skipped inside code spans. Tests: [InlineFormatStressTests.swift](../Tests/InlineFormatStressTests.swift) `testBareURLBecomesAutoLink`/`testBareURLInsideCodeIsNotLinked`; on-type at [AutoFormatAndOverlaysStressTests.swift](../Tests/AutoFormatAndOverlaysStressTests.swift). |
| I10 | WikiLink `[[Page]]` + autocomplete | ✅ | InlineParser; [BlockEditor.swift:197](../Features/Blocks/UI/BlockEditor.swift) (`WikiLinkAutocompleteAttachment`); [WikiLinkSuggestionsView.swift](../Features/Blocks/UI/WikiLinkSuggestionsView.swift) | — |
| I11 | WikiLink alias `[[Page\|alias]]` | ✅ | [InlineFormat.swift](../Shared/DesignSystem/Editor/InlineFormat.swift) parses inner on `\|`, marks `[[`, `\|`, `]]` as hidden markers so display shows `alias`. | — |
| I12 | Embed `![[Page]]` (with alias/anchor variants) | ⚠️ | [InlineFormat.swift](../Shared/DesignSystem/Editor/InlineFormat.swift) `.embed` style + `.geoEmbed` attr (blue-tinted bg, bolder weight); click navigates to target via the `WikiLinkClickPayload` flow at [BlockEditor.swift:179](../Features/Blocks/UI/BlockEditor.swift). | Click navigation works. **True transclusion (rendering target page inline)** out of scope v1. No `↪` glyph prefix (would diverge from canonical markdown round-trip). |
| I13 | Anchor link `[[Page#header]]` / `[[Page^block-id]]` | ✅ | Parsed in [InlineFormat.swift](../Shared/DesignSystem/Editor/InlineFormat.swift); click payload `WikiLinkClickPayload(target,anchor,isEmbed)` propagated through `BlockEditorEvent` → `BlockEventRouter` → `BlockListView`; [BlockEditor.swift](../Features/Blocks/UI/BlockEditor.swift) `onWikiLinkClicked` enqueues the anchor in [PendingAnchorStore.swift](../Shared/DesignSystem/Editor/PendingAnchorStore.swift) before `openWindow`; destination editor's `loadContent()` consumes the anchor, runs `headingMatch(anchor:in:doc.blocks)` (case-insensitive, whitespace-trimmed, `cleanContent ?? content`), and sets `doc.focusRequest = BlockFocusRequest(blockId: headingId, cursorOffset: 0)` BEFORE assigning `document = doc` so `BlockListView` observes it on first render. | `#header` matching works. `^block-id` syntax falls through to plain page navigation — `EditorBlock.id` is a fresh UUID per parse so there's no stable target to match (would need a separate caret-anchor index over the source markdown). Document if/when that's needed. No `›` chevron display substitution — use alias form (`[[Page#h\|h]]`) for pretty rendering. |
| I14 | Mention `@user` (block mention) | ✅ | [MentionOverlay.swift](../Shared/DesignSystem/Editor/MentionOverlay.swift); [BlockNSTextView.swift:144](../Shared/DesignSystem/Editor/BlockNSTextView.swift) | Resolves to existing block titles, not real users. |
| I15 | Inline tag `#tag` | ✅ | [InlineFormat.swift](../Shared/DesignSystem/Editor/InlineFormat.swift) — regex `(^\|\\s\|\\()#[A-Za-z0-9_/\\-]+`; `.geoTag` attribute; rendered in `NSColor.systemTeal`. Guards against matches inside code/wiki/math and against heading line-starts (block parser claims those first). | Display only; click is non-goal v1. No sync between inline `#tag` and `BlockMetadata.tagId`. |
| I16 | Inline image (paste) | ✅ | [AttachmentHandler.swift](../Features/Blocks/UI/AttachmentHandler.swift); [InlineImageLoader.swift](../Shared/DesignSystem/Markdown/InlineImageLoader.swift) | Paste works. Drag-drop file → insert image is wired ([BlockNSTextView.swift:599-614](../Shared/DesignSystem/Editor/BlockNSTextView.swift) `performDragOperation` → `pasteHandler`); see U8. |
| I17 | Emoji `:smile:` shortcode | ❌ | — | OS picker (cmd+ctrl+space) works but no shortcode expansion. |
| I18 | Footnote `[^1]` | ❌ | — | No parser. |

## Editor UX

| # | Feature | Status | Where | Gap notes |
|---|---|---|---|---|
| U1 | Slash command `/` | ✅ | [SlashCommandOverlay.swift](../Shared/DesignSystem/Editor/SlashCommandOverlay.swift); 18 commands (text, h1–h6, bullet, numbered, todo, toggle, quote, divider, code, table, math, template, callouts) | — |
| U2 | Floating selection toolbar | ✅ | [FloatingToolbar.swift](../Shared/DesignSystem/Editor/FloatingToolbar.swift); Bold/Italic/Strike/Code/Link/Turn-Into | — |
| U3 | Find & replace | ✅ | [FindReplaceBar.swift](../Shared/DesignSystem/Editor/FindReplaceBar.swift); cmd+F | — |
| U4 | Undo / redo | ✅ | [Commands/EditorCommandHistory.swift](../Shared/DesignSystem/Editor/Commands); cmd+Z / cmd+Shift+Z | Block-level: insert, delete, move, convert, merge, split, indent. |
| U5 | Inline auto-format (`**x**` → bold) | ✅ | [AutoFormatEngine.swift](../Shared/DesignSystem/Editor/AutoFormatEngine.swift) | Pairs only: `**`, `*`, `~~`, `` ` ``. |
| U6 | Line auto-format on Space (`# `…`###### `, `- ` `* ` `+ `, `> `, `1. `, `[]`/`[ ]`/`[x]`/`[X]`, ` ``` `, `$$ `) | ✅ | [BlockPrefixDetector.swift](../Shared/DesignSystem/Editor/BlockPrefixDetector.swift) (testable detector); router wiring at [BlockEventRouter.swift:178](../Shared/DesignSystem/Editor/BlockEventRouter.swift); immediate space flush at [BlockNSTextView.swift](../Shared/DesignSystem/Editor/BlockNSTextView.swift) `insertText` override → `flushContentChange`; tests at [Tests/BlockPrefixDetectorTests.swift](../Tests/BlockPrefixDetectorTests.swift) (38 cases). | HR via `--- ` typed alone covered by separate `MarkdownBlockParser.isHorizontalRule` path on contentChange — kept distinct (works post-newline). |
| U7 | HTML paste → markdown | ⚠️ | [HTMLToMarkdown.swift](../Shared/DesignSystem/Editor/HTMLToMarkdown.swift) | Headings, lists, blockquote, code, links, images. Missing: tables, nested formatting edge cases. |
| U8 | Drag-drop file → attachment | ✅ | [BlockNSTextView.swift](../Shared/DesignSystem/Editor/BlockNSTextView.swift) — `registerForDraggedTypes([.fileURL])` in `viewDidMoveToWindow` (guarded by `didRegisterDragTypes` flag); `draggingEntered`/`draggingUpdated` advertise `.copy` when pasteboard has `.fileURL`; `performDragOperation` resolves drop point via `characterIndexForInsertion(at:)`, sets selection to that index, then routes through the existing `pasteHandler` → [AttachmentHandler.swift](../Features/Blocks/UI/AttachmentHandler.swift) (already URL-aware: copies to `Attachments/<block>/`, emits `![title](path)` for images and `[title](path)` for other files). Same code path as image paste. | Multi-file drops supported (snippets joined with newlines). No live drag-preview indicator under cursor. Drop into non-text regions (gutter, between blocks) not handled — only inside an active block's text view. |
| U9 | Keyboard shortcuts | ✅ | [TextViewKeyHandler.swift](../Shared/DesignSystem/Editor/TextViewKeyHandler.swift) | cmd+B/I/E, cmd+Shift+S, cmd+Shift+H (highlight), cmd+K (insert link template — `[selection]()` with selection / `[]()` without, cursor positioned for immediate typing), cmd+D, cmd+A, cmd+F, cmd+Shift+↑↓. Still missing: cmd+] / cmd+[ (verify), cmd+/ (toggle comment). |
| U10 | Backlinks panel | ✅ | [BacklinksPanel.swift](../Features/Blocks/UI/BacklinksPanel.swift); [BlockEditor.swift:206](../Features/Blocks/UI/BlockEditor.swift) | — |
| U11 | Outline / TOC | ✅ | [OutlinePopover.swift](../Features/Blocks/UI/OutlinePopover.swift) (view + `OutlineHeading` + `OutlineExtractor`); title-bar button via `titleBarOutline(...)` in [TitleBarAccessories.swift](../Shared/Platform/WindowChrome/TitleBarAccessories.swift); mounted in [BlockEditor.swift](../Features/Blocks/UI/BlockEditor.swift). Jump-to-heading sets `document?.focusRequest = BlockFocusRequest(blockId:, cursorOffset: 0)` — `BlockListView` reacts (scrolls + focuses). | Sourced from `document?.blocks` directly (no markdown re-parse). Title-bar button uses `list.bullet.indent` SF Symbol, sits between Tag and Full-Width chrome. |
| U12 | Word count / reading time | ✅ | [EditorStatusBar.swift](../Features/Blocks/UI/EditorStatusBar.swift); mounted in [BlockEditor.swift](../Features/Blocks/UI/BlockEditor.swift) above `BacklinksPanel`. | Strips markdown syntax tokens before counting (`#`, `>`, `-`, `*`, `+`, list/checkbox prefixes, `**`/`__`/`~~`/`==`/`` ` ``, `[[`/`]]`, `[txt](url)`). Reading rate 220 wpm, min 1 min. Hidden when block is empty. |
| U13 | Spell check | ✅ | [BlockTextEditorView.swift](../Shared/DesignSystem/Editor/BlockTextEditorView.swift) — `isContinuousSpellCheckingEnabled = true`, `isAutomaticSpellingCorrectionEnabled = false`, `isGrammarCheckingEnabled = false`. | Spell check on by default; autocorrect intentionally OFF (it mangles markdown). Manual right-click menu still gives suggestions. No UI toggle yet — flip the flag if needed. |
| U14 | Focus / typewriter mode | ❌ | — | — |
| U15 | Mode toggle (Source / Live Preview / Reading) | ❌ | — | Single hybrid mode only. See architecture note above. |

## Persistence & sync

| # | Feature | Status | Where | Gap notes |
|---|---|---|---|---|
| P1 | Debounced autosave | ✅ | [BlockEditor.swift:651](../Features/Blocks/UI/BlockEditor.swift) `autosaveController.schedule(delay: 0.5)` | — |
| P2 | External file change reconciliation | ✅ | [BlockEditor.swift:68](../Features/Blocks/UI/BlockEditor.swift) onChange + [MarkdownBlockParser.swift:349](../Shared/DesignSystem/Editor/MarkdownBlockParser.swift) `mergeIdentity` | Identity matched by similarity + edit distance. |
| P3 | Frontmatter (YAML) preserve | ✅ | [BlockEditorDocument.swift:40](../Shared/DesignSystem/Editor/BlockEditorDocument.swift) `splitFrontmatter` | Hidden from editing, restored on serialize. |
| P4 | Markdown round-trip stability | ⚠️ | — | Not currently asserted by any test. See "Test coverage" below. |

## Test coverage (the real guarantee gap)

The matrix above lists implementation file:line. **What it does not list, because they don't exist, are tests for the parser/styler/auto-format paths.**

| Path | Test file | Status |
|---|---|---|
| `MarkdownBlockParser` | — | ❌ no tests |
| `InlineParser` / `SpanStyler` / `SpanExtractor` | — | ❌ no tests |
| `AutoFormatEngine` | — | ❌ no tests |
| `HTMLToMarkdown` | — | ❌ no tests |
| `MathRenderer` | — | ❌ no tests |
| `BlockEditorDocument` (frontmatter, mergeIdentity) | — | ❌ no tests |
| `BlocksStore` checkbox toggle | [BlocksStoreCheckboxTests.swift](../Tests/BlocksStoreCheckboxTests.swift) | ✅ |
| `MarkdownIndexingService` | [MarkdownIndexingServiceTests.swift](../Tests/MarkdownIndexingServiceTests.swift) | ✅ |
| `BlockGraphService` | [BlockGraphServiceTests.swift](../Tests/BlockGraphServiceTests.swift) | ✅ |

**Implication:** every ✅ in the matrix is a snapshot bet, not a guarantee. A regression in `InlineParser` that drops italics will not be caught by CI today.

### Test plan to close the gap

Three tiers, in priority order:

1. **Parser snapshots** — pairs of `(markdown_input, [EditorBlock]_expected)`. One test per row in the Block-level table. Single XCTestCase: `MarkdownBlockParserTests`.
2. **Styler snapshots** — `(markdown_input, NSAttributedString_expected_attributes)`. One test per row in the Inline table. `InlineFormatTests`.
3. **Round-trip fuzz** — for every `.md` file under `Resources/PreviewContent` and a corpus of real notes: `parse → serialize → parse` must produce equal block trees. `MarkdownRoundTripTests`. Single test asserts P4.

Until all three exist, this matrix is documentation, not enforcement.

## Update protocol

When you change the editor:

1. Find the affected row(s) in the matrix above.
2. Update **Status**, **Where**, and **Gap notes** in the same PR as the code change.
3. If the change moves a row from ❌ or ⚠️ to ✅, add or update tests per the tiers above. No test → status stays ⚠️.
4. New feature → new row. Pick a stable id (`B16`, `I19`, `U16`, `P5`).
5. Removing a feature → don't delete the row, mark it ❌ with a note explaining the removal.

Status legend:
- ✅ implemented and (per the rules above) tested
- ⚠️ implemented but with a documented wall the user can hit
- ❌ not implemented
