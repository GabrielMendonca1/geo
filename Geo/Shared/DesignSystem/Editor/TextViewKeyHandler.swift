import AppKit

struct TextViewKeyHandler {

    func handlePerformKeyEquivalent(with event: NSEvent, in textView: BlockNSTextView) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags == [.command, .shift] {
            switch event.keyCode {
            case 126:
                textView.onEvent?(.moveUp)
                return true
            case 125:
                textView.onEvent?(.moveDown)
                return true
            default:
                break
            }
            if event.charactersIgnoringModifiers == "s" || event.charactersIgnoringModifiers == "S" {
                textView.toggleInlineFormat(style: .strikethrough)
                textView.updateActiveFormattingAndToolbar()
                return true
            }
            if event.charactersIgnoringModifiers == "h" || event.charactersIgnoringModifiers == "H" {
                textView.toggleInlineFormat(style: .highlight)
                textView.updateActiveFormattingAndToolbar()
                return true
            }
        }

        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "a":
                textView.onEvent?(.selectAllBlocks)
                return true
            case "f":
                textView.onEvent?(.findRequested)
                return true
            case "d":
                textView.onEvent?(.duplicate)
                return true
            case "b":
                textView.toggleInlineFormat(style: .bold)
                textView.updateActiveFormattingAndToolbar()
                return true
            case "i":
                textView.toggleInlineFormat(style: .italic)
                textView.updateActiveFormattingAndToolbar()
                return true
            case "e":
                textView.toggleInlineFormat(style: .code)
                textView.updateActiveFormattingAndToolbar()
                return true
            case "k", "K":
                insertLinkTemplate(in: textView)
                return true
            default:
                break
            }
        }

        return false
    }

    private func insertLinkTemplate(in textView: BlockNSTextView) {
        let sel = textView.selectedRange()
        if let ts = textView.textStorage, TextViewKeyHandler.rangeOverlapsWikilink(sel, in: ts) { return }
        if sel.length > 0 {
            let selectionText = (textView.string as NSString).substring(with: sel)
            let replacement = "[\(selectionText)]()"
            textView.insertText(replacement, replacementRange: sel)
            let cursorPos = sel.location + 1 + selectionText.count + 2
            textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
        } else {
            let replacement = "[]()"
            textView.insertText(replacement, replacementRange: sel)
            let cursorPos = sel.location + 1
            textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
        }
    }

    static func rangeOverlapsWikilink(_ sel: NSRange, in ts: NSTextStorage) -> Bool {
        let length = ts.length
        guard length > 0 else { return false }
        let scanRange: NSRange = {
            if sel.length > 0 {
                let loc = max(0, sel.location)
                return NSRange(location: loc, length: min(sel.length, length - loc))
            }
            if sel.location >= length { return NSRange(location: max(0, length - 1), length: 1) }
            return NSRange(location: sel.location, length: 1)
        }()
        guard scanRange.length > 0 else { return false }
        var found = false
        ts.enumerateAttribute(.geoWikiLink, in: scanRange) { value, _, stop in
            if (value as? Bool) == true {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
