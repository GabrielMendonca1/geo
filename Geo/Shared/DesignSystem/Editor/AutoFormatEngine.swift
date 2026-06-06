import AppKit

struct AutoFormatEngine {

    struct InlinePatternMatch {
        let openRange: NSRange
        let closeRange: NSRange
        let contentRange: NSRange
    }

    func checkAndApply(in textView: BlockNSTextView) {
        guard let ts = textView.textStorage, ts.length > 0 else { return }
        let cursor = textView.selectedRange().location
        let nsText = textView.string as NSString
        guard cursor > 0 else { return }

        let patterns: [(marker: String, style: InlineStyle)] = [
            ("**", .bold),
            ("~~", .strikethrough),
            ("==", .highlight),
            ("`", .code),
        ]

        for (marker, style) in patterns {
            if let result = findInlinePattern(marker: marker, at: cursor, in: nsText) {
                applyInlineAutoFormat(
                    openRange: result.openRange,
                    closeRange: result.closeRange,
                    contentRange: result.contentRange,
                    style: style,
                    in: textView
                )
                return
            }
        }

        if let result = findSingleStarPattern(at: cursor, in: nsText) {
            applyInlineAutoFormat(
                openRange: result.openRange,
                closeRange: result.closeRange,
                contentRange: result.contentRange,
                style: .italic,
                in: textView
            )
            return
        }

        if let result = findSingleUnderscorePattern(at: cursor, in: nsText) {
            applyInlineAutoFormat(
                openRange: result.openRange,
                closeRange: result.closeRange,
                contentRange: result.contentRange,
                style: .italic,
                in: textView
            )
        }
    }

    func findInlinePattern(marker: String, at cursor: Int, in text: NSString) -> InlinePatternMatch? {
        let markerLen = (marker as NSString).length

        guard cursor >= markerLen else { return nil }
        var closeStart = cursor - markerLen
        guard text.substring(with: NSRange(location: closeStart, length: markerLen)) == marker else { return nil }

        if marker == "**" && closeStart > 0 && text.substring(with: NSRange(location: closeStart - 1, length: 1)) == "*" {
            closeStart -= 1
        }
        let closeRange = NSRange(location: closeStart, length: markerLen)

        guard closeStart > markerLen else { return nil }

        let scanLimit = max(markerLen, closeStart - 200)
        var pos = closeStart - 1
        while pos >= scanLimit {
            let candidateRange = NSRange(location: pos - markerLen, length: markerLen)
            if text.substring(with: candidateRange) == marker {
                let openStart = pos - markerLen
                let contentStart = openStart + markerLen
                let contentLength = closeStart - contentStart
                guard contentLength > 0 else { pos -= 1; continue }
                return InlinePatternMatch(
                    openRange: candidateRange,
                    closeRange: closeRange,
                    contentRange: NSRange(location: contentStart, length: contentLength)
                )
            }
            pos -= 1
        }
        return nil
    }

    func findSingleStarPattern(at cursor: Int, in text: NSString) -> InlinePatternMatch? {
        guard cursor >= 1 else { return nil }
        let closeStart = cursor - 1
        guard text.substring(with: NSRange(location: closeStart, length: 1)) == "*" else { return nil }

        if closeStart > 0 && text.substring(with: NSRange(location: closeStart - 1, length: 1)) == "*" { return nil }
        if closeStart + 1 < text.length && text.substring(with: NSRange(location: closeStart + 1, length: 1)) == "*" { return nil }

        let scanLimit = max(0, closeStart - 200)
        var pos = closeStart - 1
        while pos >= scanLimit {
            if text.substring(with: NSRange(location: pos, length: 1)) == "*" {
                if pos > 0 && text.substring(with: NSRange(location: pos - 1, length: 1)) == "*" { pos -= 1; continue }
                let contentStart = pos + 1
                let contentLength = closeStart - contentStart
                guard contentLength > 0 else { pos -= 1; continue }
                return InlinePatternMatch(
                    openRange: NSRange(location: pos, length: 1),
                    closeRange: NSRange(location: closeStart, length: 1),
                    contentRange: NSRange(location: contentStart, length: contentLength)
                )
            }
            pos -= 1
        }
        return nil
    }

    func findSingleUnderscorePattern(at cursor: Int, in text: NSString) -> InlinePatternMatch? {
        guard cursor >= 1 else { return nil }
        let closeStart = cursor - 1
        guard text.substring(with: NSRange(location: closeStart, length: 1)) == "_" else { return nil }

        if closeStart > 0 && text.substring(with: NSRange(location: closeStart - 1, length: 1)) == "_" { return nil }
        if closeStart + 1 < text.length && isWordCharacter(text, at: closeStart + 1) { return nil }

        let scanLimit = max(0, closeStart - 200)
        var pos = closeStart - 1
        while pos >= scanLimit {
            if text.substring(with: NSRange(location: pos, length: 1)) == "_" {
                if pos > 0 && text.substring(with: NSRange(location: pos - 1, length: 1)) == "_" { pos -= 1; continue }
                if pos > 0 && isWordCharacter(text, at: pos - 1) { pos -= 1; continue }
                let contentStart = pos + 1
                let contentLength = closeStart - contentStart
                guard contentLength > 0 else { pos -= 1; continue }
                return InlinePatternMatch(
                    openRange: NSRange(location: pos, length: 1),
                    closeRange: NSRange(location: closeStart, length: 1),
                    contentRange: NSRange(location: contentStart, length: contentLength)
                )
            }
            pos -= 1
        }
        return nil
    }

    private func isWordCharacter(_ text: NSString, at index: Int) -> Bool {
        let scalar = UnicodeScalar(text.character(at: index))
        guard let scalar else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    func applyInlineAutoFormat(openRange: NSRange, closeRange: NSRange, contentRange: NSRange, style: InlineStyle, in textView: BlockNSTextView) {
        guard let ts = textView.textStorage else { return }

        textView.setAutoFormatting(true)
        ts.beginEditing()
        ts.replaceCharacters(in: closeRange, with: "")
        ts.replaceCharacters(in: openRange, with: "")
        let newContentRange = NSRange(location: openRange.location, length: contentRange.length)
        textView.applyStyle(style, to: newContentRange, in: ts)
        ts.endEditing()

        let newCursor = openRange.location + contentRange.length
        textView.setSelectedRange(NSRange(location: newCursor, length: 0))
        textView.setAutoFormatting(false)
    }
}
