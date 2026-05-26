import AppKit
import Observation

@Observable
final class EditorFocusCoordinator {
    @ObservationIgnored private var liveViews: [UUID: WeakTextView] = [:]
    @ObservationIgnored private var pendingFocus: PendingFocus?
    @ObservationIgnored private(set) var cursorMemory: [UUID: Int] = [:]
    var activeFocusedBlockId: UUID?

    struct PendingFocus {
        let blockId: UUID
        let cursorOffset: Int
    }

    func register(_ tv: BlockNSTextView, for blockId: UUID) {
        liveViews[blockId] = WeakTextView(tv)
        if let pending = pendingFocus, pending.blockId == blockId {
            pendingFocus = nil
            applyFocus(tv: tv, cursorOffset: pending.cursorOffset)
        } else if blockId == activeFocusedBlockId {
            let offset = cursorMemory[blockId] ?? 0
            applyFocus(tv: tv, cursorOffset: offset)
        }
    }

    func notifyFocusGained(blockId: UUID) {
        let previous = activeFocusedBlockId
        activeFocusedBlockId = blockId
        for (id, weak) in liveViews where id != blockId {
            guard let tv = weak.value, tv.selectedRange().length > 0 else { continue }
            tv.setSelectedRange(NSRange(location: tv.selectedRange().location, length: 0))
        }
        if let previous, previous != blockId {
            liveViews[previous]?.value?.toolbarPanel?.dismiss()
        }
    }

    func notifyFocusLost(blockId: UUID) {
        saveCursorPosition(blockId: blockId)
    }

    func clearActiveFocus() {
        activeFocusedBlockId = nil
    }

    func saveCursorPosition(blockId: UUID) {
        guard let tv = liveViews[blockId]?.value else { return }
        cursorMemory[blockId] = tv.selectedRange().location
    }

    func requestFocus(blockId: UUID, cursorOffset: Int) {
        activeFocusedBlockId = blockId
        if let tv = liveViews[blockId]?.value {
            applyFocus(tv: tv, cursorOffset: cursorOffset)
        } else {
            pendingFocus = PendingFocus(blockId: blockId, cursorOffset: cursorOffset)
        }
    }

    func textView(for blockId: UUID) -> BlockNSTextView? {
        liveViews[blockId]?.value
    }

    private func applyFocus(tv: BlockNSTextView, cursorOffset: Int) {
        if let window = tv.window {
            if window.firstResponder != tv {
                window.makeFirstResponder(tv)
            }
            if cursorOffset >= 0 {
                let safe = min(cursorOffset, (tv.string as NSString).length)
                tv.setSelectedRange(NSRange(location: safe, length: 0))
            }
        } else {
            DispatchQueue.main.async { [weak tv] in
                guard let tv, let window = tv.window else { return }
                if window.firstResponder != tv {
                    window.makeFirstResponder(tv)
                }
                if cursorOffset >= 0 {
                    let safe = min(cursorOffset, (tv.string as NSString).length)
                    tv.setSelectedRange(NSRange(location: safe, length: 0))
                }
            }
        }
    }

    private struct WeakTextView {
        weak var value: BlockNSTextView?
        init(_ value: BlockNSTextView) { self.value = value }
    }
}
