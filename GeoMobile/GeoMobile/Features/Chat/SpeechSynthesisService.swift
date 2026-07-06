import AVFoundation

@MainActor
final class SpeechSynthesisService: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice = SpeechSynthesisService.preferredVoice()
    private var buffer = ""
    private var finishing = false

    var onStarted: (() -> Void)?
    var onFinished: (() -> Void)?

    private(set) var isSpeaking = false

    private static let maxChunk = 160
    private static let terminators: Set<Character> = [".", "!", "?", "\n"]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func append(_ text: String) {
        finishing = false
        buffer += text
        flushCompleteSentences()
    }

    func finish() {
        finishing = true
        let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !remaining.isEmpty {
            enqueue(remaining)
        } else if !synthesizer.isSpeaking {
            isSpeaking = false
            finishing = false
            onFinished?()
        }
    }

    func stop() {
        finishing = false
        buffer = ""
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func flushCompleteSentences() {
        while let range = nextSentenceRange() {
            let sentence = String(buffer[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(range)
            if !sentence.isEmpty { enqueue(sentence) }
        }
    }

    private func nextSentenceRange() -> Range<String.Index>? {
        if let idx = buffer.firstIndex(where: { Self.terminators.contains($0) }) {
            return buffer.startIndex..<buffer.index(after: idx)
        }
        if buffer.count >= Self.maxChunk {
            return buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: Self.maxChunk)
        }
        return nil
    }

    private func enqueue(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        if let voice { utterance.voice = voice }
        synthesizer.speak(utterance)
    }

    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let ptVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "pt-BR" }
        if let premium = ptVoices.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = ptVoices.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: "pt-BR")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
            self.onStarted?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synthesizer.isSpeaking else { return }
            guard self.finishing else { return }
            self.isSpeaking = false
            self.finishing = false
            self.onFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synthesizer.isSpeaking else { return }
            guard self.finishing else { return }
            self.isSpeaking = false
            self.finishing = false
            self.onFinished?()
        }
    }
}
