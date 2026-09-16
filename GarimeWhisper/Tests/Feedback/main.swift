import Foundation

var passes = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passes += 1
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
    }
}

func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    check(lhs == rhs, "\(label) [got: \(lhs)]")
}

print("== capture gate: reference counting ==")
do {
    var gate = FeedbackCaptureGate()
    check(!gate.isActive, "starts inactive")
    equal(gate.begin("dictation"), true, "first begin transitions to active")
    check(gate.isActive, "active after begin")
    equal(gate.begin("dictation"), false, "duplicate begin does not re-transition")
    equal(gate.depth("dictation"), 2, "duplicate begin bumps the reference count")
    equal(gate.end("dictation"), false, "first end keeps capture active")
    check(gate.isActive, "still active with one reference left")
    equal(gate.end("dictation"), true, "balanced end releases capture")
    check(!gate.isActive, "inactive after balanced ends")
}

do {
    var gate = FeedbackCaptureGate()
    equal(gate.end("ghost"), false, "end of unknown key is a no-op")
    equal(gate.depth("ghost"), 0, "unknown key never goes negative")
    gate.begin("meeting")
    gate.end("meeting")
    gate.end("meeting")
    equal(gate.depth("meeting"), 0, "extra end does not underflow")
    check(!gate.isActive, "extra end leaves the gate inactive")
}

do {
    var gate = FeedbackCaptureGate()
    gate.begin("call")
    gate.begin("dictation")
    equal(gate.reasons, ["call", "dictation"], "reasons are the sorted active keys")
    gate.end("call")
    equal(gate.reasons, ["dictation"], "releasing one reason keeps the others")
    check(gate.isActive, "any remaining reason keeps capture active")
    equal(gate.reset(), true, "reset reports it was active")
    equal(gate.reasons, [], "reset clears every reason")
    equal(gate.reset(), false, "reset on an idle gate reports inactive")
}

do {
    var gate = FeedbackCaptureGate()
    gate.begin("  dictation  ")
    equal(gate.depth("dictation"), 1, "keys are trimmed before counting")
    gate.begin("")
    equal(gate.reasons, ["dictation", "unnamed"], "empty key falls back to a named reason")
}

print("== policy: mute and disable ==")
do {
    var gate = FeedbackGate(enabled: false, volume: 0.2)
    equal(gate.evaluate(cue: .selection, now: 1), .disabled, "disabled blocks ambient cues")
    equal(gate.evaluate(cue: .error, now: 1), .disabled, "disabled blocks alert cues too")
    gate.enabled = true
    equal(gate.evaluate(cue: .error, now: 1), .play, "enabling restores playback")
}

do {
    var gate = FeedbackGate(enabled: true, volume: 0)
    equal(gate.evaluate(cue: .completed, now: 1), .muted, "zero volume mutes")
    gate.volume = 0.005
    equal(gate.evaluate(cue: .completed, now: 2), .muted, "volume below the silence threshold mutes")
    gate.volume = 0.2
    equal(gate.evaluate(cue: .completed, now: 3), .play, "audible volume plays")
}

do {
    let gate = FeedbackGate(enabled: true, volume: 99)
    equal(FeedbackVolume.clamp(gate.volume), FeedbackVolume.maximum, "volume clamps to the low ceiling")
    equal(FeedbackVolume.clamp(-3), FeedbackVolume.minimum, "negative volume clamps to zero")
    equal(FeedbackVolume.clamp(Double.nan), FeedbackVolume.fallback, "non finite volume falls back")
    check(FeedbackVolume.maximum <= 0.5, "maximum volume stays subtle")
}

print("== policy: capture suppression wins over everything ==")
do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    gate.beginCapture("dictation")
    for cue in FeedbackCue.allCases {
        equal(gate.evaluate(cue: cue, now: 10), .suppressedCapture, "\(cue.rawValue) suppressed while capturing")
    }
    equal(gate.evaluate(cue: .start, now: 10.001), .suppressedCapture, "start cue is omitted, never contaminates")
    gate.endCapture("dictation")
    equal(gate.evaluate(cue: .start, now: 11), .play, "cues resume after capture ends")
}

do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    gate.beginCapture("meeting")
    gate.beginCapture("meeting")
    gate.endCapture("meeting")
    equal(gate.evaluate(cue: .selection, now: 5), .suppressedCapture, "unbalanced release keeps suppression")
    gate.endCapture("meeting")
    equal(gate.evaluate(cue: .selection, now: 5), .play, "suppression lifts only when all reasons end")
}

do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    gate.beginCapture("call")
    gate.beginCapture("dictation")
    gate.endCapture("call")
    equal(gate.isCaptureActive, true, "one remaining microphone reason still suppresses")
    equal(gate.evaluate(cue: .error, now: 7), .suppressedCapture, "even errors stay silent during capture")
    equal(gate.resetCapture(), true, "reset releases all reasons")
    equal(gate.evaluate(cue: .error, now: 7), .play, "error plays once capture is fully released")
}

print("== policy: coalescing of repeated cues ==")
do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    equal(gate.evaluate(cue: .sectorChanged, now: 0), .play, "first sector change plays")
    equal(gate.evaluate(cue: .sectorChanged, now: 0.05), .coalesced, "repeat inside the window is coalesced")
    equal(gate.evaluate(cue: .sectorChanged, now: 0.2), .play, "repeat after the window plays again")
}

do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    equal(gate.evaluate(cue: .start, now: 0), .play, "first start plays")
    equal(gate.evaluate(cue: .start, now: 0.1), .coalesced, "duplicate start inside the lifecycle window is dropped")
    equal(gate.evaluate(cue: .start, now: 0.29), .coalesced, "duplicate start just under the window is dropped")
    equal(gate.evaluate(cue: .completed, now: 0.11), .play, "a different lifecycle cue is not coalesced")
    equal(gate.evaluate(cue: .cancelled, now: 0.12), .play, "cancel right after completion still plays")
    equal(gate.evaluate(cue: .cancelled, now: 0.13), .coalesced, "duplicate cancel is dropped")
    equal(gate.evaluate(cue: .start, now: 0.5), .play, "start plays again after its window")
}

do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    equal(gate.evaluate(cue: .error, now: 0), .play, "first error plays")
    equal(gate.evaluate(cue: .error, now: 0.4), .coalesced, "error storms collapse into one cue")
    equal(gate.evaluate(cue: .error, now: 0.5), .play, "error plays again after its long window")
}

print("== policy: global rate limit ==")
do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    equal(gate.evaluate(cue: .sectorChanged, now: 0), .play, "first ambient cue plays")
    equal(gate.evaluate(cue: .sectorChanged, now: 0.01), .coalesced, "same ambient cue inside its window is coalesced")
    equal(gate.evaluate(cue: .sectorChanged, now: 0.15), .play, "ambient cue after the window plays")
    equal(gate.evaluate(cue: .sectorChanged, now: 0.30), .play, "ambient cue keeps playing outside the gap")
}

do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    equal(gate.evaluate(cue: .completed, now: 0), .play, "lifecycle cue plays")
    equal(gate.evaluate(cue: .sectorChanged, now: 0.01), .rateLimited, "ambient cue inside the gap is rate limited")
    equal(gate.evaluate(cue: .sectorChanged, now: 0.06), .play, "ambient cue after the gap plays")
}

do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    equal(gate.evaluate(cue: .selection, now: 0), .play, "commit cue plays")
    equal(gate.evaluate(cue: .error, now: 0.001), .play, "alert cue bypasses the global gap")
    equal(gate.evaluate(cue: .completed, now: 0.002), .play, "lifecycle cue bypasses the global gap")
    equal(gate.evaluate(cue: .sectorChanged, now: 0.003), .rateLimited, "ambient cue still respects the gap")
}

print("== policy: commit confirmation outranks navigation (regression: cue B) ==")
do {
    // Clique no radial que muda de setor e confirma no mesmo evento:
    // o tick de navegação NÃO pode engolir a confirmação.
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    equal(gate.evaluate(cue: .sectorChanged, now: 0), .play, "sector tick plays on hover")
    equal(gate.evaluate(cue: .selection, now: 0.002), .play, "commit right after the tick still plays")
    equal(FeedbackCue.selection.priority, .lifecycle, "selection is a lifecycle (commit) cue")
}

do {
    // Navegação de teclado rápida seguida de Return.
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    for step in 0..<4 {
        _ = gate.evaluate(cue: .sectorChanged, now: Double(step) * 0.02)
    }
    equal(gate.evaluate(cue: .selection, now: 0.08), .play, "keyboard commit survives a burst of navigation")
    equal(gate.evaluate(cue: .selection, now: 0.085), .coalesced, "double commit is still coalesced")
    equal(gate.evaluate(cue: .selection, now: 0.2), .play, "commit plays again after its window")
}

do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    gate.beginCapture("dictation")
    equal(gate.evaluate(cue: .selection, now: 0), .suppressedCapture, "commit cue never beats capture suppression")
}

do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    equal(gate.evaluate(cue: .selection, now: 100), .play, "cue plays at a late clock")
    equal(gate.evaluate(cue: .selection, now: 1), .play, "clock going backwards resets the timings")
    equal(gate.evaluate(cue: .selection, now: Double.nan), .rateLimited, "non finite clock is refused")
}

do {
    var gate = FeedbackGate(enabled: true, volume: 0.3)
    equal(gate.evaluate(cue: .sectorChanged, now: 0), .play, "baseline cue")
    gate.forgetTimings()
    equal(gate.evaluate(cue: .sectorChanged, now: 0.001), .play, "forgetting timings clears rate limit state")
}

print("== cue catalogue ==")
do {
    equal(FeedbackCue.allCases.count, 6, "six cues exist")
    equal(Set(FeedbackCue.allCases.map { $0.rawValue }).count, 6, "cue identifiers are unique")
    equal(FeedbackCue.sectorChanged.priority, .ambient, "sector change is ambient")
    equal(FeedbackCue.selection.priority, .lifecycle, "selection (commit) is lifecycle, not ambient")
    equal(FeedbackCue.allCases.filter { $0.priority == .ambient }, [.sectorChanged],
          "only navigation is rate limited as ambient")
    equal(FeedbackCue.start.priority, .lifecycle, "start is lifecycle")
    equal(FeedbackCue.completed.priority, .lifecycle, "completed is lifecycle")
    equal(FeedbackCue.cancelled.priority, .lifecycle, "cancelled is lifecycle")
    equal(FeedbackCue.error.priority, .alert, "error is an alert")
    for cue in FeedbackCue.allCases {
        check(cue.coalesceWindow > 0, "\(cue.rawValue) has a coalescing window")
        check(cue.relativeGain > 0 && cue.relativeGain <= 1, "\(cue.rawValue) gain stays within unity")
    }
}

print("== synthesis: WAV PCM in memory (no playback, no disk) ==")

func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
    String(decoding: data[offset..<(offset + count)], as: UTF8.self)
}

func uint32(_ data: Data, _ offset: Int) -> Int {
    var value = 0
    for index in (0..<4).reversed() {
        value = value << 8 | Int(data[offset + index])
    }
    return value
}

func uint16(_ data: Data, _ offset: Int) -> Int {
    Int(data[offset]) | Int(data[offset + 1]) << 8
}

func int16(_ data: Data, _ offset: Int) -> Int {
    let raw = uint16(data, offset)
    return raw >= 0x8000 ? raw - 0x10000 : raw
}

do {
    for cue in FeedbackCue.allCases {
        let samples = FeedbackVoice.samples(for: cue)
        let data = FeedbackVoice.wav(for: cue)
        check(data.count == 44 + samples.count * 2, "\(cue.rawValue) wav size matches the synthesis")
        equal(ascii(data, 0, 4), "RIFF", "\(cue.rawValue) has a RIFF header")
        equal(ascii(data, 8, 4), "WAVE", "\(cue.rawValue) is a WAVE stream")
        equal(ascii(data, 12, 4), "fmt ", "\(cue.rawValue) declares a fmt chunk")
        equal(ascii(data, 36, 4), "data", "\(cue.rawValue) declares a data chunk")
        equal(uint32(data, 4), data.count - 8, "\(cue.rawValue) RIFF size is consistent")
        equal(uint32(data, 16), 16, "\(cue.rawValue) fmt chunk is PCM sized")
        equal(uint16(data, 20), 1, "\(cue.rawValue) is uncompressed PCM")
        equal(uint16(data, 22), 1, "\(cue.rawValue) is mono")
        equal(uint32(data, 24), Int(FeedbackVoice.sampleRate), "\(cue.rawValue) keeps the synthesis sample rate")
        equal(uint32(data, 28), Int(FeedbackVoice.sampleRate) * 2, "\(cue.rawValue) byte rate matches")
        equal(uint16(data, 32), 2, "\(cue.rawValue) block align is 16 bit mono")
        equal(uint16(data, 34), 16, "\(cue.rawValue) is 16 bit")
        equal(uint32(data, 40), samples.count * 2, "\(cue.rawValue) data chunk size matches")

        var maxError = 0.0
        var peak = 0
        for index in 0..<samples.count {
            let decoded = int16(data, 44 + index * 2)
            peak = max(peak, abs(decoded))
            maxError = max(maxError, abs(Double(decoded) / 32767 - Double(samples[index])))
        }
        check(maxError < 0.0001, "\(cue.rawValue) quantization stays under 1 LSB [got: \(maxError)]")
        check(peak > 300, "\(cue.rawValue) encodes an audible cue [peak: \(peak)]")
        check(peak <= 32767, "\(cue.rawValue) never clips the 16 bit range")
        equal(int16(data, 44), 0, "\(cue.rawValue) starts at silence (no click)")
        check(abs(int16(data, data.count - 2)) < 655, "\(cue.rawValue) ends near silence")
    }
}

do {
    let stereo = FeedbackVoice.wav(for: .selection, channels: 2)
    equal(uint16(stereo, 22), 2, "stereo request encodes two channels")
    equal(uint16(stereo, 32), 4, "stereo block align is four bytes")
    let frames = FeedbackVoice.samples(for: .selection).count
    equal(uint32(stereo, 40), frames * 4, "stereo data chunk doubles the payload")
    let interleavedMatches = (0..<frames).allSatisfy {
        int16(stereo, 44 + $0 * 4) == int16(stereo, 46 + $0 * 4)
    }
    check(interleavedMatches, "mono voice is duplicated into both channels")
}

do {
    let empty = FeedbackVoice.wav(samples: [], sampleRate: 44100)
    equal(empty.count, 44, "empty synthesis still yields a valid header")
    equal(uint32(empty, 40), 0, "empty synthesis declares an empty data chunk")
    let clipped = FeedbackVoice.wav(samples: [2, -2], sampleRate: 44100)
    equal(int16(clipped, 44), 32767, "out of range samples clamp to full scale")
    equal(int16(clipped, 46), -32767, "negative out of range samples clamp too")
    let fallback = FeedbackVoice.wav(for: .error, sampleRate: 0)
    equal(uint32(fallback, 24), Int(FeedbackVoice.sampleRate), "invalid sample rate falls back")
}

print("== preferences: persistence ==")
do {
    let suiteName = "ai.garime.whisper.feedback.tests"
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    guard let store = UserDefaults(suiteName: suiteName) else {
        check(false, "test suite defaults available")
        exit(1)
    }
    let prefs = FeedbackPreferences(store: store)
    equal(prefs.enabled, true, "sound feedback is enabled by default")
    equal(prefs.volume, FeedbackVolume.fallback, "default volume is the subtle fallback")
    prefs.enabled = false
    prefs.volume = 5
    let reread = FeedbackPreferences(store: store)
    equal(reread.enabled, false, "enabled flag persists")
    equal(reread.volume, FeedbackVolume.maximum, "volume persists clamped")
    prefs.volume = -1
    equal(FeedbackPreferences(store: store).volume, FeedbackVolume.minimum, "negative volume persists as zero")
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
}

print("== runtime: beginCapture is bounded and never waits on the audio queue ==")
do {
    let suiteName = "ai.garime.whisper.feedback.runtime.\(UUID().uuidString)"
    guard let store = UserDefaults(suiteName: suiteName) else {
        check(false, "isolated defaults available")
        exit(1)
    }
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let preferences = FeedbackPreferences(store: store)
    preferences.enabled = true
    preferences.volume = 0            // mudo: nenhum teste emite som audível
    let feedback = SoundFeedback(preferences: preferences)

    // Enche a fila de feedback com o trabalho caro (construir os players).
    feedback.warmUp()
    feedback.warmUp()
    let started = Date()
    feedback.beginCapture("dictation")
    let elapsed = Date().timeIntervalSince(started)
    check(elapsed < 0.05, "beginCapture returns in < 50ms while the queue is busy [got: \(elapsed)s]")
    check(feedback.isCaptureActive, "capture gate is closed when beginCapture returns")
    equal(feedback.play(.error), .suppressedCapture, "nothing plays once beginCapture returned")
    equal(feedback.captureReasons, ["dictation"], "runtime exposes the active reason")

    let silenced = Date()
    feedback.silenceNow()
    check(Date().timeIntervalSince(silenced) < 0.05, "silenceNow is bounded too")

    feedback.endCapture("dictation")
    check(!feedback.isCaptureActive, "balanced endCapture reopens the gate")
    equal(feedback.play(.completed), .muted, "muted runtime never reaches playback")

    // Tempestade concorrente: nada pode travar (deadlock) nem ficar negativo.
    let group = DispatchGroup()
    for worker in 0..<8 {
        DispatchQueue.global().async(group: group) {
            for step in 0..<200 {
                switch (worker + step) % 5 {
                case 0: feedback.beginCapture("stress-\(worker)")
                case 1: feedback.endCapture("stress-\(worker)")
                case 2: _ = feedback.play(.sectorChanged)
                case 3: feedback.silenceNow()
                default: _ = feedback.captureReasons
                }
            }
        }
    }
    check(group.wait(timeout: .now() + 10) == .success, "concurrent play/capture storm never deadlocks")
    feedback.resetCapture()
    check(!feedback.isCaptureActive, "resetCapture recovers a leaked gate")
    equal(feedback.captureReasons, [], "reset clears every runtime reason")
    equal(feedback.play(.completed), .muted, "runtime stays silent at zero volume after the storm")
}

print("")
print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
