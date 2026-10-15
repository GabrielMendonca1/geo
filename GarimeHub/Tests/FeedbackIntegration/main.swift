import AVFoundation
import Foundation

struct ProcessOutcome {
    let status: Int32
    let output: String
}

final class ProcessRunner {
    static var outcome = ProcessOutcome(status: 0, output: "")
    static var onRun: (() -> Void)?
    static var runCount = 0

    func reset() {}
    func cancel() {}

    func run(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> ProcessOutcome {
        Self.runCount += 1
        Self.onRun?()
        return Self.outcome
    }
}

enum Config {
    static var recStatePath = ""
    static let recPath = ""
    static let recScript = ""
    static let meetingLabel = "test"
    static let callStartTimeout: TimeInterval = 1
    static let callStopTimeout: TimeInterval = 1
    static let callLivenessInterval: TimeInterval = 60
    static let slowPollTolerance: TimeInterval = 0
}

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

print("== feedback voice synthesis (no playback) ==")
for cue in FeedbackCue.allCases {
    let layers = FeedbackVoice.layers(for: cue)
    let samples = FeedbackVoice.samples(for: cue)
    check(!layers.isEmpty, "\(cue.rawValue) has synthesis layers")
    check(!samples.isEmpty, "\(cue.rawValue) synthesizes samples")
    check(samples.allSatisfy { $0.isFinite && abs($0) <= 1 }, "\(cue.rawValue) samples are finite and bounded")
    check(samples.contains { abs($0) > 0.0001 }, "\(cue.rawValue) is not silent")
    check(abs(samples.last ?? 1) < 0.02, "\(cue.rawValue) releases near silence")
}

print("== multichannel buffer construction ==")
if let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
   let buffer = FeedbackVoice.buffer(for: .completed, format: format),
   let channels = buffer.floatChannelData {
    check(buffer.frameLength > 0, "buffer has frames")
    check(buffer.format.channelCount == 2, "buffer preserves stereo format")
    let count = Int(buffer.frameLength)
    let channelsMatch = (0..<count).allSatisfy { channels[0][$0] == channels[1][$0] }
    check(channelsMatch, "synthesized mono voice is copied to both channels")
} else {
    check(false, "stereo buffer can be constructed")
}

final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    convenience init() {
        self.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Float, forKey defaultName: String) { values[defaultName] = Double(value) }
    override func set(_ value: Int, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

print("== runtime gate integration (disabled, no playback) ==")
let defaults = MemoryDefaults()
let preferences = FeedbackPreferences(store: defaults)
preferences.enabled = false
let feedback = SoundFeedback(preferences: preferences)
check(feedback.play(.selection) == .disabled, "disabled runtime rejects playback before creating an audio engine")
feedback.beginCapture("integration")
feedback.isEnabled = true
check(feedback.isCaptureActive, "runtime capture gate activates")
check(feedback.captureDepth("integration") == 1, "runtime exposes capture depth")
check(feedback.play(.error) == .suppressedCapture, "capture suppresses enabled runtime without playback")
feedback.endCapture("integration")
check(!feedback.isCaptureActive, "runtime capture gate releases")
feedback.silenceNow()

print("== external call preflight ==")
SoundFeedback.shared.isEnabled = false
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("feedback-call-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
Config.recStatePath = temporary.appendingPathComponent("rec.state").path
let liveState = temporary.path + "\n\(getpid())\n"

let parsed = RecProbe.parse(liveState) { $0 == getpid() }
check(parsed?.active == true && parsed?.directory == temporary.path, "rec.state parser accepts a live recorder")
check(RecProbe.parse("missing-pid") { _ in true } == nil, "rec.state parser rejects malformed state")

ProcessRunner.outcome = ProcessOutcome(status: 1, output: "unexpected start output")
ProcessRunner.onRun = { try? liveState.write(toFile: Config.recStatePath, atomically: true, encoding: .utf8) }
let failedStart = CallController()
failedStart.begin()
let startDeadline = Date().addingTimeInterval(1)
while !failedStart.isRecording && Date() < startDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
check(failedStart.isRecording, "failed rec.sh result keeps capture gated when rec.state is live")
check(!failedStart.preflightFeedback(), "synchronous preflight rejects cues during an external call")
failedStart.stop()
try? FileManager.default.removeItem(atPath: Config.recStatePath)
failedStart.poll()
check(!failedStart.preflightFeedback(), "one missing poll does not prematurely reopen feedback")
failedStart.poll()

try? liveState.write(toFile: Config.recStatePath, atomically: true, encoding: .utf8)
let staleStop = CallController()
staleStop.poll()
try? FileManager.default.removeItem(atPath: Config.recStatePath)
let runsBeforeStaleStop = ProcessRunner.runCount
staleStop.finish()
if case .failed = staleStop.state {
    check(true, "stale stop becomes failure instead of success")
} else {
    check(false, "stale stop becomes failure instead of success")
}
check(ProcessRunner.runCount == runsBeforeStaleStop, "stale stop does not invoke rec.sh")

try? liveState.write(toFile: Config.recStatePath, atomically: true, encoding: .utf8)
let emptyStop = CallController()
emptyStop.poll()
ProcessRunner.outcome = ProcessOutcome(status: 0, output: "NADA GRAVANDO")
ProcessRunner.onRun = { try? FileManager.default.removeItem(atPath: Config.recStatePath) }
emptyStop.finish()
let stopDeadline = Date().addingTimeInterval(1)
while Date() < stopDeadline {
    if case .stopping = emptyStop.state {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    } else {
        break
    }
}
if case .failed = emptyStop.state {
    check(true, "NADA GRAVANDO is never reported as completed")
} else {
    check(false, "NADA GRAVANDO is never reported as completed")
}
ProcessRunner.onRun = nil

print("")
print("feedback integration passed: \(passes)   failed: \(failures)")
exit(failures == 0 ? 0 : 1)
