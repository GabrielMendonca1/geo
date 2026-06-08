import AppKit

final class EditorReconciler {
    weak var focusCoordinator: EditorFocusCoordinator?
    weak var router: BlockEventRouter?

    func reconcile(
        oldBlocks: [EditorBlock],
        newBlocks: [EditorBlock],
        excludingBlockId: UUID? = nil,
        postEditCaret: (blockId: UUID, caret: Int)? = nil
    ) {
        guard let focusCoordinator else {
            restoreCaret(postEditCaret)
            return
        }

        var oldById: [UUID: EditorBlock] = [:]
        oldById.reserveCapacity(oldBlocks.count)
        for b in oldBlocks { oldById[b.id] = b }

        for new in newBlocks {
            if new.id == excludingBlockId { continue }
            guard let old = oldById[new.id] else { continue }
            let contentEqual = old.content == new.content
            let spansEqual = old.spans == new.spans
            if contentEqual && spansEqual { continue }
            guard let tv = focusCoordinator.textView(for: new.id) else { continue }
            guard let ts = tv.textStorage else { continue }

            let wasApplying = router?.isApplyingTransaction ?? false
            router?.isApplyingTransaction = true
            defer { router?.isApplyingTransaction = wasApplying }

            let newContent = new.content
            let newSpans = new.spans
            let fullRange = NSRange(location: 0, length: ts.length)

            ts.beginEditing()
            ts.replaceCharacters(in: fullRange, with: newContent)
            let afterRange = NSRange(location: 0, length: ts.length)
            ts.setAttributes(tv.baseAttributes, range: afterRange)
            if !newSpans.isEmpty {
                SpanStyler.apply(spans: newSpans, to: ts, baseFont: tv.baseFont)
            }
            ts.endEditing()

            tv.invalidateIntrinsicContentSize()
        }
    }
}
