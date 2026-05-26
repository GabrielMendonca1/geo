# Edit operations & undo bugs

Audit of `Shared/DesignSystem/Editor/` — block-level edit operations, command stack,
selection manager, undo/redo. No production code touched.

Severity legend: CRASH > WRONG > LOSSY > MINOR > SUSPECT.

Disposition tags appear inline next to each finding's heading:
- (FIXED) — production fix landed, test updated to assert correct behavior.
- (REJECTED: <reason>) — not a real bug after investigation, or pinning a benign behavior.
- (DEFERRED: <reason>) — confirmed real but out of scope for this slice.

---

## [WRONG] (FIXED: `EditorCommandHistory` deleted entirely. `BlockEditorDocument.executeCommand(_:undoManager:)` now registers via NSUndoManager using symmetric `applyExecute`/`applyUndo` closures. `canUndo`/`undoCommand`/`redoCommand` removed from doc — callers use `undoManager.canUndo`/`.undo()`/`.redo()` directly. All 7 `executeCommand` call sites in `BlockEventRouter` updated to pass `undoManager: self.undoManager`. Tests: `testUndoStackUnified_structuralEditRegistersOnNSUndoManager`, `testUndoStackUnified_commandEditRegistersOnNSUndoManager`, `testUndoStackUnified_commandEditUndoableViaNSUndoManager`.) Dual undo stacks: NSUndoManager + EditorCommandHistory diverge silently
**Repro:** Trigger `.duplicate` event (goes through `performStructuralEdit` → NSUndoManager only) then perform an action via `executeCommand` (a `SplitBlockCommand` — goes through `EditorCommandHistory`). The two stacks contain disjoint history.
**Expected:** A single canonical undo stack so that Cmd-Z reverses the most recent action regardless of which API path produced it.
**Actual:** Two stacks. `doc.canUndo` only reflects `EditorCommandHistory`; `undoManager.canUndo` only reflects structural edits. After enough mixed actions, `undoCommand()` rewinds the wrong action and the NSUndoManager replays a now-stale snapshot.
**Where:** `Shared/DesignSystem/Editor/BlockEditorDocument.swift:102` (`performStructuralEdit`) vs `Shared/DesignSystem/Editor/Commands/EditorCommandHistory.swift:12` (`execute`). The split shows up across `BlockEventRouter` — e.g. `.duplicate`, `.indent`, `.outdent`, paste, slash commands, mentions all use `structuralEdit`, but `.split`, `.delete`, `.merge`, `.convertTo` (non-callout/toggle/math) use `executeCommand`.
**Test:** `Tests/BlockEditOpsStressTests.swift::testDualUndoStacksDiverge`

---

## [WRONG] (FIXED: dual-stack root cause resolved. Auto-format goes through `structuralEdit` which already registers with NSUndoManager; with `EditorCommandHistory` gone, the NSUndoManager IS the canonical stack. Test `testUndoAfterAutoFormatHeading_unifiedStack_undoesConversion` proves `undo.undo()` restores the paragraph after `# ` conversion.) Auto-format ("# " → heading) is invisible to the EditorCommandHistory
**Repro:** Type `# ` in an empty paragraph. The paragraph turns into a heading via `BlockEventRouter.handleContentChange` → `BlockPrefixDetector.detect` → `structuralEdit("Auto Format", ...)`. The change is captured only by the NSUndoManager.
**Expected:** A single Cmd-Z should restore the typed `# ` literal — or at minimum register a step in whatever the editor's canonical undo stack is.
**Actual:** `doc.canUndo` (EditorCommandHistory) is `false` after the conversion. Only the NSUndoManager has it, and its snapshot replay restores the empty paragraph (the typed `# ` is gone).
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:178-208` (auto-format branch) — bypasses `executeCommand`.
**Test:** `Tests/BlockEditOpsStressTests.swift::testUndoAfterAutoFormatHeading_restoresEmptyParagraph_not_HashSpace`

---

## [WRONG] (FIXED) Merging a list item into a heading swallows the bullet into the heading line
**Repro:** Two blocks: `## Title`, `- item`. Caret at start of `- item`, press Backspace.
**Expected:** Either reject the merge (heading is a "structural" block), or merge as `## Titleitem` only if user really wants that, or insert a paragraph between them.
**Actual:** `mergeWithPrevious` happily concatenates: heading content becomes `"Titleitem"`. The bullet's list semantics evaporate. Round-trip to markdown produces a single `## Titleitem` line.
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:342-365` (`mergeWithPrevious`). The kind guard only excludes `.horizontalRule, .codeBlock, .table, .image, .callout, .toggle, .mathBlock` — heading is permitted.
**Test:** `Tests/BlockEditOpsStressTests.swift::testMergeBulletIntoHeading_dropsBulletAndSwallowsIntoHeading`

---

## [WRONG] (FIXED: `BlockEventRouter.mergeWithPrevious` rejection branches now set `document.focusRequest = BlockFocusRequest(blockId: currentBlock.id, cursorOffset: 0)` and bump `editGeneration`. `BlockListView` re-pins focus and rebinds text view content from the canonical model. Test: `testMergeIntoRichBlock_rejectionResyncsView`.) Merging into a code/table/callout/toggle/math/HR is a silent no-op while text view already changed
**Repro:** Code block followed by paragraph "hello". Caret at start of paragraph, press Backspace.
**Expected:** Either block the keystroke at the text view layer, or visibly indicate the merge is rejected.
**Actual:** `mergeWithPrevious` returns early (line 346-350). The text view has already absorbed the backspace and may show a different content from the document model. The next keystroke can race the doc state out of sync.
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:342-350`
**Test:** `Tests/BlockEditOpsStressTests.swift::testMergeIntoCodeBlock_isSilentNoop_leaveDocUnchanged`

---

## [LOSSY] (FIXED: `BlockEditorEvent.split` evolved from `(String, [InlineSpan])` to `(cursorOffset: Int, after: String, spans: [InlineSpan])`. `BlockNSTextView.insertNewline` emits `selectedRange().location` as cursorOffset. `BlockEventRouter.splitBlock` uses NSString-indexed `substring(to: cursorOffset)` — no suffix matching. Tests: rewritten `testSplitBlock_truncationHeuristicLosesText`, new `testSplitBlock_cursorOffsetBeatsSuffixMatch_noCorruption`.) Split block truncation uses a fragile suffix heuristic
**Repro:** Call `.split(text: tail, …)` where `tail` is NOT a suffix of the current block's content. (Happens when the text view reports a non-suffix, e.g. after rapid composition events.)
**Expected:** Split at the cursor offset, not at `count - tail.count`.
**Actual:** When `full.hasSuffix(tail)` is false, the code falls back to `String(full.prefix(full.count - tail.count))` — silently corrupting both halves.
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:279-287` (`truncated` computation in `splitBlock`).
**Test:** `Tests/BlockEditOpsStressTests.swift::testSplitBlock_truncationHeuristicLosesText`

---

## [LOSSY] (FIXED) Splitting inside `[[wikiLink]]` leaves broken halves
**Repro:** Paragraph `see [[Page]] later`. Caret between `Pa` and `ge`, press Enter.
**Expected:** Caret snaps to end of `]]` before split fires; first half ends with intact `[[Page]]`, second half starts at ` later`.
**Fix:** `BlockNSTextView.insertNewline` reads `.geoWikiLink` attribute at caret position; if caret is strictly inside (not at boundary), snaps to `NSMaxRange(wikiRange)` before computing split content.
**Where:** `Shared/DesignSystem/Editor/BlockNSTextView.swift:664-672`
**Test:** `Tests/BlockEditOpsStressTests.swift::testSplitInsideWikiLink_textViewLayerGuardMovesCursorToEnd`, `testSplitOutsideWikiLink_preservesCursor`

---

## [WRONG] (FIXED) Indent treats every preceding block as a list sibling
**Repro:** `## section` followed by `- bullet`. Tab on the bullet.
**Expected:** Indent should require the previous list sibling to exist at the same kind/depth. Otherwise it should be a no-op (the bullet has no parent in the list sense).
**Actual:** `indentBlock` walks back with `BlockTreeNavigator.siblings`, which only checks `depth >= d`. With both items at depth 0, the heading is included as a "sibling" — `myPos > 0` is true, indent proceeds. The bullet ends up with `indent = "  "`, `depth = 1`, but its `parent(of:)` is now the heading (a non-list block).
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:574-590` (`indentBlock`) + `BlockTreeNavigator.swift:34-45` (`siblings`).
**Test:** `Tests/BlockEditOpsStressTests.swift::testIndentBulletAfterHeading_treatsHeadingAsSibling`

---

## [WRONG] (FIXED) Repeat-Tab on the same bullet stops after one level
**Repro:** Two sibling bullets. Tab twice on the second.
**Expected:** Both Tabs deepen the indent (Notion/Bear/Obsidian behavior — Tab Tab Tab pushes you deep).
**Actual:** After the first Tab, the victim block's depth no longer matches any same-depth previous sibling, so the `myPos > 0` guard fails. Second Tab silently does nothing. To reach depth 2 the user must indent two different bullets first, then re-target.
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:578-590` (`indentBlock`) — uses `BlockTreeNavigator.siblings` which only considers same-depth blocks at the same position.
**Test:** `Tests/BlockEditOpsStressTests.swift::testIndentTwiceOnSameBullet_secondPressIsNoOp`

---

## [MINOR] (REJECTED: NSBeep is aggressive UX — macOS norm (TextEdit, Notes, Obsidian) is silent no-op for Tab in non-list contexts. Real action item is "Tab inserts tab in non-list blocks", which is a feature, not a bug fix. Closing.) Indent at first sibling and outdent at depth 0 are indistinguishable silent no-ops
**Repro:** Indent the first bullet of a list; or outdent a bullet that already has no indent.
**Expected:** Audible feedback (NSBeep) or a transient UI hint.
**Actual:** Both return silently. To the user this is the same as "indent worked" — they'll press again.
**Where:** `BlockEventRouter.swift:574-590` (indent) and `:592-624` (outdent).
**Test:** `Tests/BlockEditOpsStressTests.swift::testIndentFirstSiblingIsSilentNoop`, `testOutdentAtDepthZero_silentNoop`

---

## [WRONG] (DEFERRED: behavior is debatable; carrying the parent risks more surprise than the current pinned behavior) moveBlockUp across depth mismatch silently swaps subtrees
**Repro:** Heading at index 0, parent bullet at 1, child bullet at 2. Trigger `.moveUp` on the child.
**Expected:** Refuse (the child has nowhere to go without abandoning its parent), or carry the parent with it.
**Actual:** Because `depth(child) != depth(parent)`, the non-equal-depth branch runs: child slice is removed and re-inserted at `targetSubtree.lowerBound` (i.e. the parent's index). Result: `[heading, child, parent]` — the child now sits BEFORE its (former) parent, with depth 1 but no parent above.
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:393-418` (`moveBlockUp`), specifically the `else` branch on line 407-412.
**Test:** `Tests/BlockEditOpsStressTests.swift::testMoveUpAcrossDepthMismatch_insertsAheadOfTargetSubtree`

---

## [LOSSY] (FIXED) Convert code block → paragraph loses the code body
**Repro:** Code block with body `let x = 1\nprint(x)`. Use Turn Into → paragraph (or slash command equivalent that routes through default `.convertTo` path).
**Expected:** Code body becomes paragraph text (or is offered as a multi-line paste).
**Actual:** Default convert path is `ConvertBlockCommand(originalBlock: block, convertedBlock: block.withKind(.paragraph))`. `withKind` calls `rebuild(prefix:, content:, spans:)` where `content` is the `cleanContent` (typically empty for parsed code blocks). The code body lives only in `rawText`; it never makes it into the new paragraph.
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:556-561` (default convert) → `EditorBlock.swift:269-278` (`withKind`) → `EditorBlock.swift:372-383` (`rebuild`).
**Test:** `Tests/BlockEditOpsStressTests.swift::testConvertCodeBlockToParagraph_losesCodeBody`

---

## [LOSSY] (FIXED) Convert toggle → callout drops the toggle title
**Repro:** Toggle with title `My Section`, body `body`. Turn Into → callout.
**Expected:** Title preserved either as callout title or first line of body.
**Actual:** `convertBlock` for the toggle→callout case uses `block.toggleContent ?? ""` and passes through `Self.convertedBlock(content:, kind:)`. The title is never read.
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:477-496` (`convertBlock` toggle-source branch).
**Test:** `Tests/BlockEditOpsStressTests.swift::testConvertToggleToCallout_dropsToggleTitle`

---

## [SUSPECT] (REJECTED: existing test passes today; EditorBlock.callout splits body correctly) Convert paragraph containing newlines → callout — body line splitting fragile
**Repro:** Paragraph whose `cleanContent` somehow includes `\n` (e.g. multi-line paste then immediate convert). Turn Into → callout.
**Expected:** Each line prefixed with `> `, valid Obsidian callout.
**Actual:** `EditorBlock.callout(... content:)` does split body lines correctly. The risk is that elsewhere `cleanContent` is treated as a single line — verify the round-trip parses back to the same body. Test passes today but is a regression sentinel.
**Where:** `EditorBlock.swift:240-253` (`EditorBlock.callout`).
**Test:** `Tests/BlockEditOpsStressTests.swift::testConvertParagraphWithNewlines_toCallout_lostBodyPrefix`

---

## [LOSSY] (FIXED: `copySelectedBlocks` now maps to `\.rawText` and joins without separator — same path as `BlockSerializer.serialize`. Preserves code fences, table pipes, callout markers, etc. across all block kinds. Tests: `testCopySelectedCodeBlock_preservesFencesAndBody`, `testCopySelectedMixedKinds_preservesEachRawText`.) copySelectedBlocks ignores rich kinds (code/table/image) and emits empty/joined content
**Repro:** Select a code block via block-handle Cmd+click, press Cmd-C.
**Expected:** Pasteboard contains the code fence + body (`\`\`\`\nbody\n\`\`\``) or at least the body.
**Actual:** `copySelectedBlocks` does `blocks.filter(...).map(\.content).joined(separator: "\n")`. `EditorBlock.content` for a code block returns either `rawText` or a substring driven by `contentRange`; depending on parse vs synthetic construction the result is unstable. Empty/garbled clipboard for code blocks, tables, images, math blocks.
**Where:** `Shared/DesignSystem/Editor/BlockSelectionManager.swift:122-129`.
**Test:** `Tests/BlockEditOpsStressTests.swift::testCopySelectedCodeBlock_copiesEmptyString`

---

## [SUSPECT] (REJECTED: command stack is strict LIFO today; pin-test is informational only) SplitBlockCommand.undo trusts blockIndex but commands stack can reorder under it
**Repro:** Execute `SplitBlockCommand(blockIndex: 0)`, then `InsertBlockCommand(index: 1)`, then undo twice.
**Expected:** Today's behavior — passes because undo is strict LIFO. But the invariant is fragile: any future "smart" reordering of the command stack (coalescing, partial replay) breaks this.
**Actual:** Works today because the test framework does plain LIFO. Pinned to prevent silent regressions.
**Where:** `Commands/SplitBlockCommand.swift:17-25` — relies on `blockIndex` being unchanged.
**Test:** `Tests/BlockEditOpsStressTests.swift::testSplitUndo_afterInterveningInsert_removesWrongBlock`

---

## [MINOR] (REJECTED: bounds guard already in place; cycle scenarios not reachable from current event paths) No cycle prevention or upper-bound on subtree move
**Repro:** Parent bullet with a child. `.moveDown` on parent.
**Expected:** Move parent + child together past the next sibling (today's intent), or no-op.
**Actual:** Guard `subtree.upperBound < document.blocks.count` (line 425) makes it a silent no-op when the subtree reaches the end. No cycle guard — relies on subtreeRange not extending out of bounds, which is true for now but undefended.
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:420-445` (`moveBlockDown`).
**Test:** `Tests/BlockEditOpsStressTests.swift::testMoveBlockDown_pastOwnSubtree_currentlyCallsNoop`, `testMoveDownLastBlockIsNoOp`

---

## [SUSPECT] (FIXED: `BlockEventRouter.handleContentChange` clears `slashState` and `mentionState` when `BlockPrefixDetector.detect` returns an outcome; covered by `testSlashStateClearedByAutoFormat` + `testMentionStateClearedByAutoFormat`. `handleContentChange` made `mutating` to allow the assignment.) Slash state persists across auto-format that replaces the block
**Repro:** Open slash menu (state stored on router) by typing `/`. While menu is open, paste/type content that triggers a code-block auto-format (`\`\`\`` ).
**Expected:** Slash state cleared when the underlying block is reshaped.
**Actual:** Slash state lives on the `BlockEventRouter` and is only cleared by `.slashDismissed` events from the text view. The auto-format structural edit does not emit a dismiss. Visually the slash menu floats over a code block until the user moves the caret.
**Where:** `BlockEventRouter.swift:178-208` (auto-format) and `:55-57` (`slashDismissed` is the only reset path).
**Test:** `Tests/BlockEditOpsStressTests.swift::testSlashStateSurvivesAutoFormat`

---

## [SUSPECT] (FIXED: `handleFocus` clears `slashState`/`mentionState` when the new focused blockId differs from the state's blockId. Covers app-switch / different-block-click / cross-block typing scenarios. Tests: `testMentionStateClearedOnFocusChange`, `testSlashStateClearedOnFocusChange`, `testMentionStateSurvivesSameBlockFocus`.) Mention state has no timeout / sanity reset
**Repro:** Activate mention (`[[`). Switch app focus. Return.
**Expected:** Mention overlay reset.
**Actual:** State survives — only an explicit `mentionDismissed` event clears it. Same architectural issue as slash state.
**Where:** `BlockEventRouter.swift:58-70`.
**Test:** `Tests/BlockEditOpsStressTests.swift::testMentionStateExplicitReset`

---

## [MINOR] (FIXED: `BlockEventRouter.pasteLines` caps at `pasteLineCap = 500`. Lines beyond cap dropped with `os.log warning("paste truncated: <n> lines → 500 (cap)")`. Tests: `testPasteLines_cappedAt500_logsWarning`, `testPasteLines_underCap_unchanged`.) Paste with 100+ lines creates 100+ blocks, no batching
**Repro:** Cmd-V a 1000-line block of text into an empty paragraph.
**Expected:** Either a paste cap with a confirmation, or batch-rendered insertion (today's `structuralEdit` allocates one `EditorBlock` per line in a single mutation pass).
**Actual:** 1000 blocks land in one structural edit; the renderer + height calculator process them all synchronously. UI freeze risk on bulk paste from web pages.
**Where:** `BlockEventRouter.swift:626-660` (`pasteLines`).
**Test:** `Tests/BlockEditOpsStressTests.swift::testPasteOneHundredLines_creates100Blocks`

---

## [MINOR] (REJECTED: lives in MarkdownBlockParser, which is Agent 1's lane) renumberOrderedRuns silently rewrites user-typed ordered numbers
**Repro:** Insert an ordered item with `number: 42` into a list of `1, 2`. Any subsequent structural edit invokes `renumberOrderedRuns`.
**Expected:** This is mostly desired behavior, but it should be opt-out for "raw" inserts (programmatic API uses, templates) where the caller wants to preserve numbering.
**Actual:** Every command and every structural edit rewrites all ordered-item numbers. User-specified numbers are clobbered.
**Where:** `Shared/DesignSystem/Editor/MarkdownBlockParser.swift:410-444` (`renumberOrderedRuns`) — called by both `performStructuralEdit` (line 112) and `EditorCommandHistory.execute/undo/redo`.
**Test:** `Tests/BlockEditOpsStressTests.swift::testInsertOrderedItemWithHighNumber_isRenumberedOnNextEdit`

---

## [SUSPECT] (REJECTED: id-based focus is correct; the index-based concern is a future regression sentinel, not a present bug) deleteBlock at index 0 with N>1 blocks focuses on the next sibling at offset 0
**Repro:** Two paragraphs. Delete the first.
**Expected:** Cursor at start of remaining paragraph — matches today's behavior.
**Actual:** Works; but the `else if subtree.upperBound < document.blocks.count` branch at `BlockEventRouter.swift:326-329` reads `document.blocks[subtree.upperBound]` BEFORE the structural delete. After the delete, that index points to a different block — but the focus targets are computed by `id`, so it's safe today. Pinned in case anyone refactors the focus to be index-based.
**Where:** `Shared/DesignSystem/Editor/BlockEventRouter.swift:311-340`.
**Test:** _(not directly tested — pin via integration test)_

---

## [SUSPECT] (REJECTED: iteration is currently via document.blocks.filter, which preserves order) BlockSelectionManager.copySelectedBlocks ignores document order from the selection set
**Repro:** Cmd-click block at index 3, then Cmd-click block at index 1, Cmd-C.
**Expected:** Pasteboard contains them in document order (1 before 3).
**Actual:** Today `copySelectedBlocks` iterates `document.blocks.filter { selectedBlockIds.contains($0.id) }` — which IS in document order. Good. Pinned because the selection set is `Set<UUID>`, so any future change to iterate the set instead of the doc reintroduces the bug.
**Where:** `Shared/DesignSystem/Editor/BlockSelectionManager.swift:122-129`.
**Test:** _(implicit in `testCopySelectedCodeBlock_copiesEmptyString`)_

---

## Notes / patterns

1. **Two undo paths is the root cause** of several findings. Auto-format, indent/outdent, duplicate, paste, slash commands, and most "Turn Into" branches use `performStructuralEdit`; split / merge / delete / `ConvertBlockCommand` plain path use `executeCommand`. Pick one — preferably `EditorCommandHistory` since it's structured and testable — and route every mutator through it.

2. **"Silent no-op" pattern is everywhere.** Indent first sibling, outdent depth 0, move first up, move last down, merge into rich block. All of them return early with no audible/visible feedback. A central `editorRejected(_ reason:)` hook would help.

3. **`content` accessor is overloaded.** For paragraphs it returns `cleanContent`. For code/math/callout/toggle it returns a different substring depending on `contentRange`. Consumers (`copySelectedBlocks`, `convertedBlock`, `withKind`) assume "give me the plain text" — but for rich blocks the body lives in `rawText`. Worth aliasing: `plainContent` vs `rawBody`.

4. **`BlockPrefixDetector` only fires when content has a trailing space.** Pasting `# Heading` (no trailing space) does NOT auto-format — silently inconsistent with typing. Worth documenting or fixing.
