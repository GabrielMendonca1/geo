import AVFoundation
import Foundation

@MainActor
final class VoiceSessionController: ObservableObject {
    enum State { case idle, listening, thinking, speaking }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var isActive = false
    @Published private(set) var isHolding = false

    var isRecording: Bool { state == .listening || isHolding }
    var onPermissionDenied: (() -> Void)?

    private let audioSession = AudioSessionManager()
    private let recognition = SpeechRecognitionService()
    private let synthesis = SpeechSynthesisService()
    private weak var viewModel: ChatViewModel?
    private var modality = ResponseModality()

    private var sessionActive = false
    private var micRunning = false

    private var vadTimer: Timer?
    private var spokeThisTurn = false
    private var lastVoiceAt = Date()

    private var bargeEnergyRun: TimeInterval = 0
    private var lastLevelAt = Date()

    private var holdContinuation: CheckedContinuation<String, Never>?

    private let voiceLevel: Float = 0.02
    private let bargeLevel: Float = 0.06
    private let silenceInterval: TimeInterval = 1.0
    private let bargeSustain: TimeInterval = 0.35

    func bind(_ viewModel: ChatViewModel) {
        guard self.viewModel == nil else { return }
        self.viewModel = viewModel
        viewModel.onThinking = { [weak self] in self?.handleThinking() }
        viewModel.onAssistantDelta = { [weak self] delta in self?.handleDelta(delta) }
        viewModel.onAssistantCompleted = { [weak self] text in self?.handleCompleted(text) }
        viewModel.onStreamEnded = { [weak self] in self?.handleStreamEnded() }
        viewModel.onStreamFailed = { [weak self] in self?.handleStreamFailed() }
        recognition.onPartial = { [weak self] text in self?.handlePartial(text) }
        recognition.onFinal = { [weak self] text in self?.handleFinal(text) }
        recognition.onError = { [weak self] in self?.handleRecognitionError() }
        recognition.onLevel = { [weak self] level in self?.handleLevel(level) }
        synthesis.onFinished = { [weak self] in self?.handleSpeechFinished() }
        audioSession.onInterruption = { [weak self] began in self?.handleInterruption(began) }
        audioSession.onRouteChange = { [weak self] in self?.handleRouteChange() }
    }

    func toggleConversation() {
        if isActive { stopConversation() } else { startConversation() }
    }

    private func startConversation() {
        isActive = true
        synthesis.stop()
        Task {
            guard await requestPermissions() else {
                isActive = false
                onPermissionDenied?()
                return
            }
            startListeningTurn()
        }
    }

    private func stopConversation() {
        isActive = false
        stopVADTimer()
        stopMic()
        synthesis.stop()
        state = .idle
        transcript = ""
        releaseSession()
    }

    private func startListeningTurn() {
        guard isActive else { return }
        guard ensureSession() else { stopConversation(); return }
        stopMic()
        transcript = ""
        spokeThisTurn = false
        lastVoiceAt = Date()
        modality = ResponseModality()
        guard startMic() else { stopConversation(); return }
        state = .listening
        startVADTimer()
    }

    private func autoSend() {
        guard state == .listening else { return }
        let message = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        stopVADTimer()
        stopMic()
        transcript = ""
        state = .thinking
        guard let viewModel else { return }
        viewModel.draft = message
        Task {
            let started = await viewModel.send()
            if !started { self.recoverFromFailedSend() }
        }
    }

    private func recoverFromFailedSend() {
        guard isActive, state == .thinking else { return }
        startListeningTurn()
    }

    private func handleThinking() {
        guard isActive, state != .speaking else { return }
        state = .thinking
    }

    private func handleDelta(_ delta: String) {
        guard isActive else { return }
        let step = modality.ingest(delta)
        if step.fallback { synthesis.stop() }
        if !step.speak.isEmpty {
            if state != .speaking { enterSpeaking() }
            synthesis.append(step.speak)
        }
    }

    private func handleCompleted(_ text: String) {
        closeResponse()
    }

    private func handleStreamEnded() {
        closeResponse()
    }

    private func handleStreamFailed() {
        guard isActive else { return }
        synthesis.stop()
        if state != .idle { startListeningTurn() }
    }

    private func closeResponse() {
        guard isActive else { return }
        let tail = modality.flush()
        if !tail.isEmpty {
            if state != .speaking { enterSpeaking() }
            synthesis.append(tail)
        }
        synthesis.finish()
        if state != .speaking { advanceAfterSpeech() }
    }

    private func enterSpeaking() {
        state = .speaking
        bargeEnergyRun = 0
        lastLevelAt = Date()
        _ = startMic()
    }

    private func handleSpeechFinished() {
        guard isActive, state == .speaking else { return }
        advanceAfterSpeech()
    }

    private func advanceAfterSpeech() {
        guard isActive else { state = .idle; return }
        startListeningTurn()
    }

    private func bargeIn() {
        guard state == .speaking else { return }
        synthesis.stop()
        viewModel?.cancelStreaming()
        modality = ResponseModality()
        stopMic()
        transcript = ""
        guard startMic() else { stopConversation(); return }
        state = .listening
        spokeThisTurn = true
        lastVoiceAt = Date()
        startVADTimer()
    }

    private func handlePartial(_ text: String) {
        if isHolding { transcript = text; return }
        guard isActive, state == .listening else { return }
        transcript = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            spokeThisTurn = true
            lastVoiceAt = Date()
        }
    }

    private func handleFinal(_ text: String) {
        if isHolding {
            transcript = text
            finishHold()
            return
        }
        guard isActive, state == .listening else { return }
        transcript = text
        autoSend()
    }

    private func handleRecognitionError() {
        if isHolding { finishHold(); return }
        guard isActive else { return }
        if state == .listening {
            if recognition.isAvailable { startListeningTurn() } else { stopConversation() }
        }
    }

    private func handleLevel(_ level: Float) {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastLevelAt), 0.1)
        lastLevelAt = now
        switch state {
        case .listening:
            if level > voiceLevel {
                spokeThisTurn = true
                lastVoiceAt = now
            }
        case .speaking:
            if level > bargeLevel {
                bargeEnergyRun += dt
                if bargeEnergyRun >= bargeSustain { bargeIn() }
            } else {
                bargeEnergyRun = 0
            }
        default:
            break
        }
    }

    private func handleInterruption(_ began: Bool) {
        guard isActive else { return }
        if began {
            synthesis.stop()
            stopMic()
            sessionActive = false
            state = .thinking
        } else if ensureSession() {
            startListeningTurn()
        }
    }

    private func handleRouteChange() {
        guard isActive, state == .listening else { return }
        sessionActive = false
        startListeningTurn()
    }

    func beginHold() {
        guard !isActive, !isHolding else { return }
        isHolding = true
        transcript = ""
        synthesis.stop()
        Task {
            guard await requestPermissions() else {
                isHolding = false
                onPermissionDenied?()
                return
            }
            guard ensureSession(), startMic() else {
                isHolding = false
                releaseSession()
                return
            }
        }
    }

    func endHold() async -> String {
        guard isHolding else { return transcript }
        recognition.stopAudio()
        return await withCheckedContinuation { continuation in
            holdContinuation = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                self.finishHold()
            }
        }
    }

    private func finishHold() {
        guard isHolding else { return }
        isHolding = false
        stopMic()
        releaseSession()
        if let continuation = holdContinuation {
            holdContinuation = nil
            continuation.resume(returning: transcript)
        }
    }

    private func startMic() -> Bool {
        guard !micRunning else { return true }
        guard recognition.start() else { return false }
        micRunning = true
        return true
    }

    private func stopMic() {
        guard micRunning else { return }
        recognition.cancel()
        micRunning = false
    }

    private func ensureSession() -> Bool {
        if sessionActive { return true }
        do {
            try audioSession.activateConversation()
            sessionActive = true
            return true
        } catch {
            return false
        }
    }

    private func releaseSession() {
        guard sessionActive else { return }
        audioSession.deactivate()
        sessionActive = false
    }

    private func startVADTimer() {
        stopVADTimer()
        vadTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkVAD() }
        }
    }

    private func stopVADTimer() {
        vadTimer?.invalidate()
        vadTimer = nil
    }

    private func checkVAD() {
        guard isActive, state == .listening, spokeThisTurn else { return }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if Date().timeIntervalSince(lastVoiceAt) >= silenceInterval { autoSend() }
    }

    private func requestPermissions() async -> Bool {
        guard await SpeechRecognitionService.requestSpeechAuthorization() else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
