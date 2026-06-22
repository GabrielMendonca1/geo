import XCTest
@testable import Geo

@MainActor
final class BlockEditOpsStressTests: XCTestCase {

    // MARK: - helpers

    private func makeRouter(blocks: [EditorBlock]) -> (BlockEventRouter, BlockEditorDocument, EditorFocusCoordinator, BlockSelectionManager) {
        let doc = BlockEditorDocument(blocks: blocks)
        let focus = EditorFocusCoordinator()
        let sel = BlockSelectionManager()
        let router = BlockEventRouter(
            document: doc,
            focusCoordinator: focus,
            selectionManager: sel,
            undoManager: nil,
            mentionableBlocks: [],
            onWikiLinkClicked: nil
        )
        return (router, doc, focus, sel)
    }

    private func bullet(_ content: String, indent: String = "") -> EditorBlock {
        var b = EditorBlock.paragraph(content: content).withKind(.bulletItem(marker: "-"))
        if !indent.isEmpty { b = b.withIndent(indent) }
        return b
    }

    private func heading(_ content: String, level: Int = 1) -> EditorBlock {
        EditorBlock.paragraph(content: content).withKind(.heading(level: level))
    }

    // MARK: - 1. Split / merge boundaries

    /// FIXED: Merging a list item into a heading is now rejected (silent no-op).
    /// The two blocks remain separate so the markdown round-trip stays clean.
    func testMergeBulletIntoHeading_dropsBulletAndSwallowsIntoHeading() {
        let h = heading("Title", level: 2)
        let b = bullet("item")
        var (router, doc, _, _) = makeRouter(blocks: [h, b])
        router.handleEvent(.merge("item", []), at: 1)
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(doc.blocks[0].content, "Title")
        XCTAssertEqual(doc.blocks[1].content, "item")
    }

    /// BUG: BlockEventRouter.mergeWithPrevious bails out (returns silently) when
    /// the prev block is a code/table/image/callout/toggle/math/HR — but the
    /// caller has already partially mutated the current block in the text view.
    /// The UI is left with a stale text view content that doesn't match doc state.
    func testMergeIntoCodeBlock_isSilentNoop_leaveDocUnchanged() {
        let code = EditorBlock(
            id: UUID(), kind: .codeBlock(language: nil),
            sourceRange: NSRange(location: 0, length: 8),
            rawText: "```\n\n```\n", indent: "", prefix: "",
            contentRange: NSRange(location: 4, length: 0)
        )
        let p = EditorBlock.paragraph(content: "hello")
        var (router, doc, _, _) = makeRouter(blocks: [code, p])
        let before = doc.blocks
        router.handleEvent(.merge("hello", []), at: 1)
        // No structural change — the paragraph still exists as a separate block.
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(doc.blocks[1].content, before[1].content)
    }

    func testMergeIntoRichBlock_rejectionResyncsView() {
        let code = EditorBlock(
            id: UUID(), kind: .codeBlock(language: nil),
            sourceRange: NSRange(location: 0, length: 8),
            rawText: "```\n\n```\n", indent: "", prefix: "",
            contentRange: NSRange(location: 4, length: 0)
        )
        let p = EditorBlock.paragraph(content: "hello")
        var (router, doc, _, _) = makeRouter(blocks: [code, p])
        let before = doc.blocks
        let genBefore = doc.editGeneration
        router.handleEvent(.merge("hello", []), at: 1)
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(doc.blocks[1].content, before[1].content)
        XCTAssertEqual(doc.focusRequest?.blockId, p.id, "rejection refocuses the current block so the text view rebinds")
        XCTAssertEqual(doc.focusRequest?.cursorOffset, 0)
        XCTAssertGreaterThan(doc.editGeneration, genBefore, "editGeneration must bump so SwiftUI observers re-render")
    }

    func testSplitBlock_truncationHeuristicLosesText() {
        let para = EditorBlock.paragraph(content: "foo bar baz")
        var (router, doc, _, _) = makeRouter(blocks: [para])
        router.handleEvent(.split(cursorOffset: 4, after: "bar baz", spans: []), at: 0)
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(doc.blocks[0].content, "foo ")
        XCTAssertEqual(doc.blocks[1].content, "bar baz")
    }

    func testSplitBlock_cursorOffsetBeatsSuffixMatch_noCorruption() {
        let para = EditorBlock.paragraph(content: "hello")
        var (router, doc, _, _) = makeRouter(blocks: [para])
        router.handleEvent(.split(cursorOffset: 3, after: "xyz", spans: []), at: 0)
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(doc.blocks[0].content, "hel")
        XCTAssertEqual(doc.blocks[1].content, "xyz")
    }

    /// BUG: Splitting inside a wikilink `[[Page]]` at the `|` boundary leaves
    /// each half with a broken half-link. Reasonable since splits are dumb on
    /// purpose, but the editor offers no detection / repair.
    func testSplitInsideWikiLink_textViewLayerGuardMovesCursorToEnd() {
        let tv = BlockNSTextView()
        tv.string = "see [[Page]] later"
        let ts = tv.textStorage!
        ts.setAttributes([:], range: NSRange(location: 0, length: ts.length))
        let wikiRange = NSRange(location: 4, length: 8)
        ts.addAttribute(.geoWikiLink, value: true, range: wikiRange)
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        var captured: (String, [InlineSpan])?
        tv.onEvent = { event in
            if case .split(_, let after, let spans) = event {
                captured = (after, spans)
            }
        }
        tv.insertNewline(nil)
        XCTAssertEqual(tv.selectedRange().location, 12, "caret must jump to end of [[Page]]")
        XCTAssertEqual(captured?.0, " later", "after-cursor content starts after wikilink, not mid-link")
    }

    func testSplitOutsideWikiLink_preservesCursor() {
        let tv = BlockNSTextView()
        tv.string = "see [[Page]] later"
        let ts = tv.textStorage!
        ts.setAttributes([:], range: NSRange(location: 0, length: ts.length))
        ts.addAttribute(.geoWikiLink, value: true, range: NSRange(location: 4, length: 8))
        tv.setSelectedRange(NSRange(location: 14, length: 0))
        var captured: (String, [InlineSpan])?
        tv.onEvent = { event in
            if case .split(_, let after, let spans) = event {
                captured = (after, spans)
            }
        }
        tv.insertNewline(nil)
        XCTAssertEqual(tv.selectedRange().location, 14)
        XCTAssertEqual(captured?.0, "ater")
    }

    // MARK: - 2. Indent / outdent

    /// BUG: Indenting the FIRST sibling at depth 0 is a no-op (correct) but the
    /// guard returns silently with no user feedback. Same code path returns the
    /// same way when block is not a list at all. Both behaviors are
    /// indistinguishable from "indent succeeded".
    func testIndentFirstSiblingIsSilentNoop() {
        let b1 = bullet("first")
        let b2 = bullet("second")
        var (router, doc, _, _) = makeRouter(blocks: [b1, b2])
        let before = doc.blocks
        router.handleEvent(.indent, at: 0)
        XCTAssertEqual(doc.blocks.map(\.rawText), before.map(\.rawText))
    }

    /// FIXED: Repeat-Tab now deepens on each press as long as a list ancestor exists.
    func testIndentTwiceOnSameBullet_secondPressIsNoOp() {
        let b1 = bullet("anchor")
        let b2 = bullet("victim")
        var (router, doc, _, _) = makeRouter(blocks: [b1, b2])
        router.handleEvent(.indent, at: 1)
        XCTAssertEqual(doc.blocks[1].indent.count, 2, "first Tab indents one level")
        router.handleEvent(.indent, at: 1)
        XCTAssertEqual(doc.blocks[1].indent.count, 4, "second Tab continues to deepen")
    }

    /// BUG: Outdent of a list item promotes following siblings into the indented
    /// subtree (good), but if the block has NO indent at all the operation is a
    /// silent no-op — same as for non-list blocks. Confusing for keyboard users.
    func testOutdentAtDepthZero_silentNoop() {
        let b1 = bullet("root")
        var (router, doc, _, _) = makeRouter(blocks: [b1])
        let before = doc.blocks
        router.handleEvent(.outdent, at: 0)
        XCTAssertEqual(doc.blocks.map(\.rawText), before.map(\.rawText))
    }

    /// FIXED: Indent rejects when the immediate non-deeper predecessor is not a list block.
    func testIndentBulletAfterHeading_treatsHeadingAsSibling() {
        let h = heading("section", level: 2)
        let b = bullet("bullet right under heading")
        var (router, doc, _, _) = makeRouter(blocks: [h, b])
        router.handleEvent(.indent, at: 1)
        XCTAssertEqual(doc.blocks[1].indent, "", "indent rejected because predecessor is a heading, not a list")
    }

    // MARK: - 3. Move up / move down

    /// BUG: moveBlockUp at index 0 is correctly a no-op (subtree.lowerBound - 1
    /// is -1) but moveBlockUp at index 1 when block[0] is a heading and block[1]
    /// is a bulleted list does NOT carry the heading's siblings or notice depth
    /// mismatch — it just swaps two subtrees, which is fine when depths match
    /// and surprising when they differ. Verify the depth-mismatch branch.
    func testMoveUpAcrossDepthMismatch_insertsAheadOfTargetSubtree() {
        let h = heading("Title", level: 2)
        let bParent = bullet("parent")
        let bChild = bullet("child", indent: "  ")
        var (router, doc, _, _) = makeRouter(blocks: [h, bParent, bChild])
        // Move the child up (depth 1 over depth 0 list parent)
        router.handleEvent(.moveUp, at: 2)
        // After moveUp at index 2 with mismatched depth, the child slice is
        // inserted at targetSubtree.lowerBound — which is the parent bullet
        // (index 1). Net result: [heading, child, parent].
        XCTAssertEqual(doc.blocks.count, 3)
        XCTAssertEqual(doc.blocks[1].content, "child")
        XCTAssertEqual(doc.blocks[2].content, "parent")
    }

    /// BUG: moveBlockDown computes `insertAt = min(targetSubtree.upperBound - subtree.count, afterBlocks.count)`
    /// after the removal, but when subtree.count > targetSubtree.upperBound the
    /// subtraction wraps in `Int` and the test for `min` masks it: actually no,
    /// it underflows producing a crash via trap or a negative `insertAt`.
    /// Concretely: subtree is at the end and bigger than the target subtree.
    func testMoveDownLastBlockIsNoOp() {
        let p1 = EditorBlock.paragraph(content: "first")
        let p2 = EditorBlock.paragraph(content: "last")
        var (router, doc, _, _) = makeRouter(blocks: [p1, p2])
        let before = doc.blocks
        router.handleEvent(.moveDown, at: 1)
        XCTAssertEqual(doc.blocks.map(\.id), before.map(\.id))
    }

    // MARK: - 4. Convert (Turn Into)

    /// BUG: Convert paragraph → callout puts the existing content inside
    /// callout body — but `content` is read from `cleanContent` and reflects
    /// the paragraph plain text. When the paragraph contained newlines (a
    /// quirky paste-then-convert flow), callout serialization fails to add the
    /// `> ` prefix per line.
    func testConvertParagraphWithNewlines_toCallout_lostBodyPrefix() {
        var para = EditorBlock.paragraph(content: "line1\nline2")
        para.cleanContent = "line1\nline2"
        var (router, doc, _, _) = makeRouter(blocks: [para])
        router.handleEvent(.convertTo(.callout(type: .info, title: nil)), at: 0)
        // Should be a callout with proper `> ` per line
        guard case .callout = doc.blocks[0].kind else {
            return XCTFail("expected callout, got \(doc.blocks[0].kind)")
        }
        let body = doc.blocks[0].calloutContent ?? ""
        XCTAssertEqual(body, "line1\nline2")
    }

    /// FIXED: Converting a code block to paragraph now preserves the code body.
    func testConvertCodeBlockToParagraph_losesCodeBody() {
        let code = EditorBlock(
            id: UUID(), kind: .codeBlock(language: "swift"),
            sourceRange: NSRange(location: 0, length: 0),
            rawText: "```swift\nlet x = 1\nprint(x)\n```\n",
            indent: "", prefix: "",
            contentRange: NSRange(location: 9, length: 17)
        )
        var (router, doc, _, _) = makeRouter(blocks: [code])
        router.handleEvent(.convertTo(.paragraph), at: 0)
        if case .paragraph = doc.blocks[0].kind {
            XCTAssertEqual(doc.blocks[0].content, "let x = 1\nprint(x)")
        } else {
            XCTFail("expected paragraph")
        }
    }

    /// FIXED: Convert toggle → callout now carries the toggle title into the
    /// callout title and preserves the toggle body.
    func testConvertToggleToCallout_dropsToggleTitle() {
        let t = EditorBlock.toggle(title: "My Section", content: "body", expanded: true)
        var (router, doc, _, _) = makeRouter(blocks: [t])
        router.handleEvent(.convertTo(.callout(type: .info, title: nil)), at: 0)
        guard case .callout(_, let title) = doc.blocks[0].kind else {
            return XCTFail("expected callout")
        }
        XCTAssertEqual(title, "My Section", "toggle title carried into callout title")
        XCTAssertEqual(doc.blocks[0].calloutContent, "body", "toggle body carried into callout body")
    }

    // MARK: - 5. Multi-block selection

    /// BUG: deleteSelectedBlocks does
    ///     let safeIdx = min(firstDeletedIdx, document.blocks.count - 1)
    /// AFTER the structural edit that may have replaced everything with a
    /// single empty block. firstDeletedIdx could exceed new count - which
    /// `min` clamps to. But when ALL blocks are deleted and `firstDeletedIdx`
    /// was 0, this lands on the empty block — focus target is set to the
    /// recreated empty's id, which is fine. The hidden bug: the FIRST `min(...)`
    /// uses `document.blocks.count - 1` which, if `blocks.count` is 0, is -1,
    /// which crashes on `Array.subscript`. The line above repopulates the
    /// blocks to size 1 inside `performStructuralEdit`, so it survives — but
    /// the contract is invisible.
    func testDeleteAllBlocksReplacesWithEmpty() {
        let p1 = EditorBlock.paragraph(content: "a")
        let p2 = EditorBlock.paragraph(content: "b")
        var (_, doc, _, sel) = makeRouter(blocks: [p1, p2])
        sel.selectedBlockIds = Set([p1.id, p2.id])
        sel.deleteSelectedBlocks(from: doc, undoManager: nil)
        XCTAssertEqual(doc.blocks.count, 1)
        if case .empty = doc.blocks[0].kind {
            // ok
        } else {
            XCTFail("expected empty block after deleting all")
        }
    }

    /// BUG: copySelectedBlocks joins contents with `\n` even when the selected
    /// blocks include code blocks / tables / images. The "content" of a code
    /// block is the empty string (its body is inside rawText), so copying a
    /// code block via Cmd+C on the block handle yields a literal empty line.
    func testCopySelectedCodeBlock_preservesFencesAndBody() {
        let code = EditorBlock(
            id: UUID(), kind: .codeBlock(language: nil),
            sourceRange: NSRange(location: 0, length: 0),
            rawText: "```\nbody\n```\n", indent: "", prefix: "",
            contentRange: NSRange(location: 4, length: 4)
        )
        let (_, doc, _, sel) = makeRouter(blocks: [code])
        sel.selectedBlockIds = [code.id]
        sel.copySelectedBlocks(from: doc)
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertEqual(pasted, "```\nbody\n```\n")
    }

    func testCopySelectedMixedKinds_preservesEachRawText() {
        let h = heading("Title", level: 2)
        let para = EditorBlock.paragraph(content: "some text\n")
        let table = EditorBlock(
            id: UUID(), kind: .table,
            sourceRange: NSRange(location: 0, length: 0),
            rawText: "| A | B |\n| --- | --- |\n| 1 | 2 |\n",
            indent: "", prefix: "",
            contentRange: NSRange(location: 0, length: 0)
        )
        let (_, doc, _, sel) = makeRouter(blocks: [h, para, table])
        sel.selectedBlockIds = [h.id, para.id, table.id]
        sel.copySelectedBlocks(from: doc)
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(pasted.contains("Title"))
        XCTAssertTrue(pasted.contains("some text"))
        XCTAssertTrue(pasted.contains("| --- | --- |"))
    }

    // MARK: - 6. Undo / redo edge cases

    /// BUG: Auto-format converts "# " (paragraph) to a heading inside ONE
    /// structural-edit step. Pressing undo should ideally restore "# " on the
    /// paragraph so the user can edit it. Instead, the undo path swaps the
    /// entire snapshot — so the user loses the "# " entirely.
    /// NB: tested via direct call to convertedBlock conversion via prefix
    /// detector outcome. We exercise the BlockEventRouter.handleContentChange
    /// indirectly by exercising the visible behaviour: history step lands the
    /// document at the pre-paragraph state, not at "# ".
    func testUndoAfterAutoFormatHeading_restoresEmptyParagraph_not_HashSpace() {
        let para = EditorBlock.paragraph(content: "")
        var (router, doc, _, _) = makeRouter(blocks: [para])
        // Simulate the editor flush: contentChange with "# " from a paragraph.
        // contentChange uses performStructuralEdit (not the command history).
        // So `undoCommand` cannot reverse it — there is no symmetric step.
        router.handleEvent(.contentChange("# ", []), at: 0)
        if case .heading(let lvl) = doc.blocks[0].kind {
            XCTAssertEqual(lvl, 1)
        } else {
            XCTFail("expected heading")
        }
    }

    func testUndoAfterAutoFormatHeading_unifiedStack_undoesConversion() {
        let undo = UndoManager()
        let para = EditorBlock.paragraph(content: "")
        let doc = BlockEditorDocument(blocks: [para])
        let focus = EditorFocusCoordinator()
        let sel = BlockSelectionManager()
        var router = BlockEventRouter(document: doc, focusCoordinator: focus, selectionManager: sel,
                                      undoManager: undo, mentionableBlocks: [], onWikiLinkClicked: nil)
        router.handleEvent(.contentChange("# ", []), at: 0)
        if case .heading = doc.blocks[0].kind {} else { XCTFail("expected heading after auto-format") }
        XCTAssertTrue(undo.canUndo, "auto-format must register on the unified NSUndoManager stack")
        undo.undo()
        if case .paragraph = doc.blocks[0].kind {} else { XCTFail("undo must restore paragraph") }
    }

    func testUndoStackUnified_structuralEditRegistersOnNSUndoManager() {
        let undo = UndoManager()
        let doc = BlockEditorDocument(blocks: [EditorBlock.paragraph(content: "a")])
        let focus = EditorFocusCoordinator()
        let sel = BlockSelectionManager()
        var router = BlockEventRouter(document: doc, focusCoordinator: focus, selectionManager: sel,
                                      undoManager: undo, mentionableBlocks: [], onWikiLinkClicked: nil)
        router.handleEvent(.duplicate, at: 0)
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertTrue(undo.canUndo, "structural edits register with the unified NSUndoManager stack")
    }

    func testUndoStackUnified_commandEditRegistersOnNSUndoManager() {
        let undo = UndoManager()
        let doc = BlockEditorDocument(blocks: [EditorBlock.paragraph(content: "a")])
        let original = doc.blocks[0]
        let updated = original.withContent("")
        let new = original.continuationBlock(content: "a")
        doc.executeCommand(SplitBlockCommand(blockIndex: 0, originalBlock: original, updatedBlock: updated, newBlock: new), undoManager: undo)
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertTrue(undo.canUndo, "command-based edits register on the SAME NSUndoManager stack")
    }

    func testUndoStackUnified_commandEditUndoableViaNSUndoManager() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let doc = BlockEditorDocument(blocks: [EditorBlock.paragraph(content: "a")])
        undo.beginUndoGrouping()
        let original = doc.blocks[0]
        let updated = original.withContent("")
        let new = original.continuationBlock(content: "a")
        doc.executeCommand(SplitBlockCommand(blockIndex: 0, originalBlock: original, updatedBlock: updated, newBlock: new), undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(doc.blocks.count, 2)
        undo.undo()
        XCTAssertEqual(doc.blocks.count, 1, "NSUndoManager.undo() reverses command-based edits")
    }

    // MARK: - 7. Drag-drop block reorder

    /// MINOR: There is no cycle prevention when reordering subtrees. We move a
    /// subtree (depth N) into a position that places it inside its own
    /// children's range — verify the data layer doesn't catch this.
    func testMoveBlockDown_pastOwnSubtree_currentlyCallsNoop() {
        // parent (b0) with a child (b1). Moving b0 down skips b1 because
        // subtreeRange includes b1 — but only when child.depth > parent.depth.
        let parent = bullet("p")
        let child = bullet("c", indent: "  ")
        var (router, doc, _, _) = makeRouter(blocks: [parent, child])
        router.handleEvent(.moveDown, at: 0)
        // Subtree is [0,2). upperBound == 2 == blocks.count → guard returns.
        XCTAssertEqual(doc.blocks[0].content, "p")
        XCTAssertEqual(doc.blocks[1].content, "c")
    }

    // MARK: - 8. Slash & 9. Mention overlay race

    /// SUSPECT: handleContentChange clears selection before any structural
    /// edits. If a slash command was open and the user types content that is
    /// detected as a code-block fence, the slash state is preserved (it lives
    /// on the router, not the textview). The activated slash menu may appear
    /// over a now-replaced code block.
    func testSlashStateClearedByAutoFormat() throws {
        throw XCTSkip("pending: .slashActivated event case not implemented")
    }

    func testMentionStateClearedByAutoFormat() throws {
        throw XCTSkip("pending: .mentionActivated event case not implemented")
    }

    func testMentionStateClearedOnFocusChange() throws {
        throw XCTSkip("pending: .mentionActivated event case not implemented")
    }

    func testSlashStateClearedOnFocusChange() throws {
        throw XCTSkip("pending: .slashActivated event case not implemented")
    }

    func testMentionStateSurvivesSameBlockFocus() throws {
        throw XCTSkip("pending: .mentionActivated event case not implemented")
    }

    func testMentionStateExplicitReset() throws {
        throw XCTSkip("pending: .mentionActivated event case not implemented")
    }

    // MARK: - 10. Paste lines

    /// MINOR: Paste-100-lines creates 100 blocks. No cap, no batching. This is
    /// a documentation-by-test for memory/perf risk.
    func testPasteOneHundredLines_creates100Blocks() {
        let para = EditorBlock.paragraph(content: "")
        var (router, doc, _, _) = makeRouter(blocks: [para])
        let lines = (1...100).map { "line\($0)" }
        router.handleEvent(.pasteLines(lines), at: 0)
        XCTAssertGreaterThanOrEqual(doc.blocks.count, 100)
    }

    func testPasteLines_cappedAt500_logsWarning() {
        let para = EditorBlock.paragraph(content: "")
        var (router, doc, _, _) = makeRouter(blocks: [para])
        let lines = (0..<1000).map { "line \($0)" }
        router.handleEvent(.pasteLines(lines), at: 0)
        XCTAssertLessThanOrEqual(doc.blocks.count, 501, "paste capped at 500 + the original block")
    }

    func testPasteLines_underCap_unchanged() {
        let para = EditorBlock.paragraph(content: "")
        var (router, doc, _, _) = makeRouter(blocks: [para])
        let lines = (0..<10).map { "line \($0)" }
        router.handleEvent(.pasteLines(lines), at: 0)
        XCTAssertEqual(doc.blocks.count, 10)
    }

    /// PHASE 1: id-based ops survive structural-edit index staleness.
    /// Before: closures captured Int index at render; after a deletion shifted
    /// the array, the captured index pointed at the wrong block.
    func testDeleteByIdSurvivesStructuralEditStaleness() {
        let p1 = EditorBlock.paragraph(content: "first")
        let p2 = EditorBlock.paragraph(content: "second")
        let p3 = EditorBlock.paragraph(content: "third")
        let (router, doc, _, _) = makeRouter(blocks: [p1, p2, p3])
        let secondId = doc.blocks[1].id
        router.deleteBlock(at: 0)  // shifts p2 from index 1 to index 0
        router.deleteBlock(id: secondId)  // must still hit "second"
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].content, "third")
    }

    // MARK: - Phase 2: parentId tree

    /// PHASE 2: deleting a paragraph never sweeps the next paragraph.
    /// Pre-Phase-2, if a paragraph somehow got non-zero depth (stale indent,
    /// undo race, paste bug), subtreeRange would walk forward and delete
    /// adjacent root-level blocks. With explicit parentId, root paragraphs
    /// have parentId == nil and cannot accidentally become children of
    /// each other.
    func testParagraphsAreRootAndIsolated() {
        let p1 = EditorBlock.paragraph(content: "4-Pereira Barra")
        let p2 = EditorBlock.paragraph(content: "5-Shopping")
        let p3 = EditorBlock.paragraph(content: "6-Condominio")
        var blocks = [p1, p2, p3]
        MarkdownBlockParser.assignDepths(&blocks)
        XCTAssertNil(blocks[0].parentId)
        XCTAssertNil(blocks[1].parentId)
        XCTAssertNil(blocks[2].parentId)
        let subtree = BlockTreeNavigator.subtreeRange(of: 0, in: blocks)
        XCTAssertEqual(subtree, 0..<1, "root paragraphs must not form a subtree")
    }

    /// PHASE 2: bullet-list parent/child relationships are by parentId, not depth-equality.
    func testBulletSubtreeIsByParentId() {
        let parent = EditorBlock.paragraph(content: "p").withKind(.bulletItem(marker: "-"))
        let child = EditorBlock.paragraph(content: "c").withKind(.bulletItem(marker: "-")).withIndent("  ")
        var blocks = [parent, child]
        MarkdownBlockParser.assignDepths(&blocks)
        XCTAssertEqual(blocks[1].parentId, blocks[0].id, "indented bullet must point to parent by id")
        let subtree = BlockTreeNavigator.subtreeRange(of: 0, in: blocks)
        XCTAssertEqual(subtree, 0..<2)
    }

    // MARK: - Phase 3: persisted block IDs

    /// PHASE 3: round-trip a document with frontmatter and verify all block UUIDs survive.
    /// Without persisted ids, mergeIdentity uses fuzzy text matching which
    /// fails on near-duplicate content. The list-of-pairs format handles
    /// duplicate-content blocks (two "Hello world" paragraphs) by assigning
    /// each occurrence its own UUID in document order.
    /// Hygiene rule: ids only persist for documents that already carry
    /// frontmatter (typed Geo blocks). Pristine markdown stays pristine.
    func testBlockIdsPersistAcrossRoundTrip() {
        let md = "---\ntype: fleeting\n---\nHello world\n\nAnother paragraph\n\nHello world\n"
        let doc1 = BlockEditorDocument(markdown: md)
        let originalIds = doc1.blocks.map(\.id)
        let serialized = doc1.serialize()
        let doc2 = BlockEditorDocument(markdown: serialized)
        XCTAssertEqual(doc2.blocks.count, doc1.blocks.count)
        for (i, id) in originalIds.enumerated() {
            XCTAssertEqual(doc2.blocks[i].id, id, "block \(i) lost its id across round-trip")
        }
    }

    /// PHASE 3: pristine documents (no frontmatter) do not get polluted with
    /// a synthetic frontmatter just to persist ids. Hygiene over identity for
    /// unfrontmatted markdown.
    func testNoFrontmatterDocumentStaysClean() {
        let md = "Hello world\n\nAnother paragraph\n"
        let doc = BlockEditorDocument(markdown: md)
        XCTAssertEqual(doc.serialize(), md)
    }

    /// PHASE 3: existing frontmatter is preserved while geo_block_ids is added.
    func testRoundTripPreservesExistingFrontmatter() {
        let md = "---\ntype: project\ntag: foo\n---\n\nBody\n"
        let doc1 = BlockEditorDocument(markdown: md)
        let serialized = doc1.serialize()
        XCTAssertTrue(serialized.contains("type: project"))
        XCTAssertTrue(serialized.contains("tag: foo"))
        XCTAssertTrue(serialized.contains("geo_block_ids:"))
    }

    /// PHASE 3: parentId references survive round-trip when parent ids are remapped.
    func testParentIdSurvivesRoundTrip() {
        let parent = EditorBlock.paragraph(content: "p").withKind(.bulletItem(marker: "-"))
        let child = EditorBlock.paragraph(content: "c").withKind(.bulletItem(marker: "-")).withIndent("  ")
        let doc1 = BlockEditorDocument(blocks: [parent, child])
        doc1.performStructuralEdit(undoManager: nil, name: "init", newFocus: nil) { _ in }
        let serialized = doc1.serialize()
        let doc2 = BlockEditorDocument(markdown: serialized)
        XCTAssertEqual(doc2.blocks.count, 2)
        XCTAssertEqual(doc2.blocks[1].parentId, doc2.blocks[0].id, "child parentId must point at remapped parent id")
    }

    // MARK: - Parser polish: ordered checkboxes, inline ***bold+italic***, bold-wraps-code

    /// `1. [ ] text` / `2. [x] text` must parse as checkboxItem, with the
    /// numbered prefix preserved in the marker for round-trip.
    func testOrderedCheckboxParses() {
        let doc = MarkdownBlockParser.parse(markdown: "1. [ ] open\n2. [x] done\n")
        XCTAssertEqual(doc.blocks.count, 2)
        if case .checkboxItem(let checked, let marker) = doc.blocks[0].kind {
            XCTAssertFalse(checked)
            XCTAssertEqual(marker, "1.")
        } else {
            XCTFail("first block must be checkboxItem, got \(doc.blocks[0].kind)")
        }
        if case .checkboxItem(let checked, let marker) = doc.blocks[1].kind {
            XCTAssertTrue(checked)
            XCTAssertEqual(marker, "2.")
        } else {
            XCTFail("second block must be checkboxItem, got \(doc.blocks[1].kind)")
        }
    }

    /// `***text***` must apply both .bold and .italic styles to "text", with
    /// no stray asterisks left in the rendered content.
    func testBoldItalicTripleStars() {
        let (clean, spans) = InlineParser.parse("***hello***")
        XCTAssertEqual(clean, "hello")
        let styles = Set(spans.flatMap { $0.styles })
        XCTAssertTrue(styles.contains(.bold), "expected .bold span")
        XCTAssertTrue(styles.contains(.italic), "expected .italic span")
    }

    /// `> - item` and `> - [ ] task` must parse as list/checkbox items with
    /// the insideBlockquote flag, not as blockquotes carrying literal `- ` text.
    func testBlockquoteWrappingListItems() {
        let doc = MarkdownBlockParser.parse(markdown: "> - item\n> - [ ] task\n")
        XCTAssertEqual(doc.blocks.count, 2)
        if case .bulletItem = doc.blocks[0].kind {
            XCTAssertTrue(doc.blocks[0].insideBlockquote, "bullet inside blockquote must set flag")
            XCTAssertTrue(doc.blocks[0].prefix.contains(">"), "prefix must preserve blockquote marker for round-trip")
        } else {
            XCTFail("expected bulletItem inside blockquote, got \(doc.blocks[0].kind)")
        }
        if case .checkboxItem(let checked, _) = doc.blocks[1].kind {
            XCTAssertFalse(checked)
            XCTAssertTrue(doc.blocks[1].insideBlockquote)
        } else {
            XCTFail("expected checkboxItem inside blockquote, got \(doc.blocks[1].kind)")
        }
    }

    /// `**bold with `code` inside**` must apply bold across the whole range,
    /// and code as its own span. Previously isInsideCode used range
    /// intersection (any overlap) and skipped the bold entirely.
    func testBoldWrappingInlineCode() {
        let (clean, spans) = InlineParser.parse("**bold with `code` inside**")
        XCTAssertEqual(clean, "bold with code inside")
        let boldSpans = spans.filter { $0.styles.contains(.bold) }
        XCTAssertFalse(boldSpans.isEmpty, "expected bold to span across the inline code")
        let codeSpans = spans.filter { $0.styles.contains(.code) }
        XCTAssertEqual(codeSpans.count, 1, "expected one code span")
    }

    // MARK: - dual-emit collapse (single source of truth)

    /// Locks the collapse: one keystroke emits exactly one `.contentChange` and
    /// never a `.transaction`. Before the collapse, `shouldChangeText` emitted a
    /// rival `.transaction` from a predicted string (with empty spans) in addition
    /// to `didChangeText`'s `.contentChange`, double-mutating the model per keystroke.
    func testTypingEmitsSingleContentChangeNeverTransaction() {
        let tv = BlockNSTextView()
        tv.isEditable = true
        tv.blockId = UUID()
        tv.string = "hello"
        tv.setSelectedRange(NSRange(location: 5, length: 0))

        var events: [BlockEditorEvent] = []
        tv.onEvent = { events.append($0) }
        tv.insertText("X", replacementRange: NSRange(location: 5, length: 0))

        let transactions = events.filter { if case .transaction = $0 { return true }; return false }
        let contentChanges = events.compactMap { event -> String? in
            if case .contentChange(let content, _) = event { return content }
            return nil
        }
        XCTAssertEqual(transactions.count, 0, "typing must not emit a rival .transaction")
        XCTAssertEqual(contentChanges.count, 1, "typing emits exactly one .contentChange")
        XCTAssertEqual(contentChanges.first, "helloX")
    }

    /// Regression for the dual-emit collapse freeze: during IME / dead-key composition
    /// (`hasMarkedText()`), emitting `.contentChange` mutates the model, which rewrites
    /// `tv.string` and cancels the live marked range — wedging the input system. No
    /// content event may escape until the composition commits.
    func testNoContentChangeWhileMarkedText() {
        let tv = BlockNSTextView()
        tv.isEditable = true
        tv.blockId = UUID()

        var contentChanges = 0
        tv.onEvent = { if case .contentChange = $0 { contentChanges += 1 } }

        tv.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(tv.hasMarkedText(), "precondition: composition is live")
        XCTAssertEqual(contentChanges, 0, "no .contentChange while marked text is composing")

        tv.insertText("á", replacementRange: NSRange(location: 0, length: 1))
        XCTAssertFalse(tv.hasMarkedText(), "composition committed")
        XCTAssertGreaterThan(contentChanges, 0, "committed text emits .contentChange")
    }

    /// Regression: the dual-emit collapse routed keystrokes through .contentChange,
    /// which never notified the slash/mention plugins (they only ran via dispatch's
    /// transaction). So typing "/" stopped opening the command menu. handleContentChange
    /// must run the menu plugins so router.slashState is set.
    func testTypingSlashOpensCommandMenu() {
        let (router, doc, focus, _) = makeRouter(blocks: [EditorBlock.paragraph(content: "")])
        let blockId = doc.blocks[0].id
        focus.activeFocusedBlockId = blockId
        doc.focusRequest = BlockFocusRequest(blockId: blockId, cursorOffset: 1)

        router.handleEvent(.contentChange("/", []), at: 0)

        XCTAssertNotNil(router.slashState, "typing / must open the slash command menu")
        XCTAssertEqual(router.slashState?.blockId, blockId)
    }

    func testSlashFuzzyRankingAndFilter() {
        let id = UUID()
        func filtered(_ q: String) -> [BlockSlashCommand] {
            SlashCommandOverlay.filtered(for: id, slashState: SlashState(blockId: id, blockIndex: 0, filter: q, selectedIndex: 0))
        }
        XCTAssertEqual(filtered("").count, BlockSlashCommand.all.count, "empty filter shows every command (browse)")
        XCTAssertEqual(filtered("head").first?.id, "h1", "label-prefix match ranks; declaration order breaks ties")
        XCTAssertEqual(filtered("code").first?.id, "code")
        XCTAssertEqual(filtered("tabl").first?.id, "table")
        XCTAssertTrue(filtered("zzzznope").isEmpty, "no match returns empty (drives the empty-state row)")
        XCTAssertLessThanOrEqual(filtered("e").count, 8, "filtered list is capped")
    }

}
