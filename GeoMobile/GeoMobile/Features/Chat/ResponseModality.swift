import Foundation

@MainActor
final class ResponseModality {
    enum Decision { case pending, speak, text }

    struct Step {
        var speak: String = ""
        var fallback = false
    }

    private(set) var decision: Decision = .pending
    private var head = ""
    private var markerResolved = false
    private var speakTail = ""

    private static let holdLimit = 160
    private static let terminators: Set<Character> = [".", "!", "?", "\n"]
    private static let voiceMarker = "⟦voice⟧"
    private static let textMarker = "⟦text⟧"

    func ingest(_ delta: String) -> Step {
        switch decision {
        case .text:
            return Step()
        case .speak:
            if (speakTail + delta).contains("```") {
                decision = .text
                speakTail = ""
                return Step(fallback: true)
            }
            speakTail = String((speakTail + delta).suffix(2))
            return Step(speak: delta)
        case .pending:
            head += delta
            resolveMarker()
            switch decision {
            case .text:
                head = ""
                return Step()
            case .speak:
                let out = head
                head = ""
                return Step(speak: out)
            case .pending:
                if head.contains("```") {
                    decision = .text
                    head = ""
                    return Step()
                }
                if head.count >= Self.holdLimit || head.contains(where: { Self.terminators.contains($0) }) {
                    decide()
                    if decision == .speak {
                        let out = head
                        head = ""
                        return Step(speak: out)
                    }
                    head = ""
                    return Step()
                }
                return Step()
            }
        }
    }

    func flush() -> String {
        if decision == .pending { decide() }
        guard decision == .speak, !head.isEmpty else { head = ""; return "" }
        let out = head
        head = ""
        return out
    }

    private func resolveMarker() {
        guard !markerResolved else { return }
        let trimmed = String(head.drop(while: { $0.isWhitespace }))
        if trimmed.isEmpty { return }
        if trimmed.hasPrefix(Self.voiceMarker) {
            head = String(trimmed.dropFirst(Self.voiceMarker.count))
            decision = .speak
            markerResolved = true
            return
        }
        if trimmed.hasPrefix(Self.textMarker) {
            decision = .text
            markerResolved = true
            return
        }
        if Self.voiceMarker.hasPrefix(trimmed) || Self.textMarker.hasPrefix(trimmed) {
            return
        }
        markerResolved = true
    }

    private func decide() {
        decision = looksLikeText(head) ? .text : .speak
    }

    private func looksLikeText(_ s: String) -> Bool {
        if s.contains("```") { return true }
        if s.contains("](") || s.contains("http://") || s.contains("https://") { return true }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let bulletLines = lines.filter { line in
            let t = String(line).trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") { return true }
            let dotted = t.prefix(3)
            return dotted.count >= 2 && dotted.first?.isNumber == true && dotted.contains(".")
        }
        if bulletLines.count >= 2 { return true }
        let tableLines = lines.filter { $0.filter { $0 == "|" }.count >= 2 }
        if !tableLines.isEmpty { return true }
        if s.count >= Self.holdLimit && !s.contains(where: { Self.terminators.contains($0) }) { return true }
        return false
    }
}
