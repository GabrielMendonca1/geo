import AVFoundation
import Speech

@MainActor
final class SpeechRecognitionService {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: (() -> Void)?
    var onLevel: ((Float) -> Void)?

    private(set) var usesOnDevice = false
    private(set) var degradedToNetwork = false

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    static func requestSpeechAuthorization() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    func start() -> Bool {
        guard let recognizer, recognizer.isAvailable else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            usesOnDevice = true
            degradedToNetwork = false
        } else {
            usesOnDevice = false
            degradedToNetwork = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.rms(buffer)
            Task { @MainActor in self?.onLevel?(level) }
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.request = nil
            return false
        }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.onPartial?(result.bestTranscription.formattedString)
                    if result.isFinal {
                        self.onFinal?(result.bestTranscription.formattedString)
                    }
                }
                if error != nil {
                    self.onError?()
                }
            }
        }
        return true
    }

    func stopAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
    }

    func cancel() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        return (sum / Float(count)).squareRoot()
    }
}
