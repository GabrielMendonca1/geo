import AppKit
import CoreGraphics

final class Typist: TextSink {
    func emit(_ text: String) -> Bool {
        let sanitized = TextChunker.sanitize(text)
        guard !sanitized.isEmpty else { return true }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        for chunk in TextChunker.chunks(sanitized, limit: Config.typistChunkUTF16) {
            guard Typist.post(chunk, source: source) else { return false }
        }
        return true
    }

    private static func post(_ chunk: String, source: CGEventSource) -> Bool {
        var units = Array(chunk.utf16)
        guard !units.isEmpty else { return true }
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
