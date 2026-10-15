import AVFoundation
import Foundation

final class SoundFeedback {
    static let shared = SoundFeedback()

    private let queue = DispatchQueue(label: "ai.garime.hub.feedback", qos: .userInitiated)
    private let lock = NSLock()
    private let preferences: FeedbackPreferences

    private var gate: FeedbackGate
    private var players: [FeedbackCue: AVAudioPlayer] = [:]
    private var sounding: [ObjectIdentifier: AVAudioPlayer] = [:]
    private var idleGeneration = 0

    init(preferences: FeedbackPreferences = FeedbackPreferences()) {
        self.preferences = preferences
        self.gate = FeedbackGate(enabled: preferences.enabled, volume: preferences.volume)
    }

    var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return gate.enabled
        }
        set {
            lock.lock()
            gate.enabled = newValue
            gate.forgetTimings()
            lock.unlock()
            preferences.enabled = newValue
            if !newValue { silenceNow() }
        }
    }

    var volume: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return gate.volume
        }
        set {
            let clamped = FeedbackVolume.clamp(newValue)
            lock.lock()
            gate.volume = clamped
            lock.unlock()
            preferences.volume = clamped
            if FeedbackVolume.isSilent(clamped) { silenceNow() }
        }
    }

    var isCaptureActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gate.isCaptureActive
    }

    var captureReasons: [String] {
        lock.lock()
        defer { lock.unlock() }
        return gate.captureReasons
    }

    func captureDepth(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return gate.captureDepth(key)
    }

    func beginCapture(_ key: String) {
        lock.lock()
        gate.beginCapture(key)
        gate.forgetTimings()
        lock.unlock()
        silenceNow()
    }

    func endCapture(_ key: String) {
        lock.lock()
        gate.endCapture(key)
        lock.unlock()
    }

    func resetCapture() {
        lock.lock()
        gate.resetCapture()
        lock.unlock()
    }

    @discardableResult
    func play(_ cue: FeedbackCue) -> FeedbackDecision {
        let now = SoundFeedback.monotonicNow()
        lock.lock()
        let decision = gate.evaluate(cue: cue, now: now)
        let amplitude = FeedbackVolume.clamp(gate.volume) * cue.relativeGain
        lock.unlock()
        guard decision.isAudible else { return decision }
        queue.async { [weak self] in
            self?.emit(cue, amplitude: amplitude)
        }
        return decision
    }

    func warmUp() {
        queue.async { [weak self] in
            guard let self else { return }
            for cue in FeedbackCue.allCases {
                if self.isCaptureActive { return }
                _ = self.preparedPlayer(cue)
            }
        }
    }

    func silenceNow() {
        lock.lock()
        let snapshot = Array(sounding.values)
        sounding.removeAll()
        idleGeneration += 1
        lock.unlock()
        for player in snapshot {
            player.stop()
            player.currentTime = 0
        }
    }

    static func monotonicNow() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private func emit(_ cue: FeedbackCue, amplitude: Double) {
        guard isCaptureActive == false else { return }
        guard let player = preparedPlayer(cue) else { return }

        lock.lock()
        guard gate.enabled, !gate.isCaptureActive, !FeedbackVolume.isSilent(gate.volume) else {
            lock.unlock()
            return
        }
        player.volume = Float(max(0, min(1, amplitude)))
        player.currentTime = 0
        player.play()
        sounding[ObjectIdentifier(player)] = player
        lock.unlock()

        scheduleIdleRelease()
    }

    private func preparedPlayer(_ cue: FeedbackCue) -> AVAudioPlayer? {
        if let existing = players[cue] { return existing }
        let data = FeedbackVoice.wav(for: cue)
        guard let player = try? AVAudioPlayer(data: data) else { return nil }
        player.prepareToPlay()
        players[cue] = player
        return player
    }

    private func scheduleIdleRelease() {
        lock.lock()
        idleGeneration += 1
        let generation = idleGeneration
        lock.unlock()
        queue.asyncAfter(deadline: .now() + FeedbackTiming.idleTeardownDelay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = self.idleGeneration != generation
            let idle = self.sounding.values.allSatisfy { !$0.isPlaying }
            if !stale, idle { self.sounding.removeAll() }
            self.lock.unlock()
        }
    }
}
