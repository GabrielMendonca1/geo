import AVFoundation
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

print("")
print("feedback integration passed: \(passes)   failed: \(failures)")
exit(failures == 0 ? 0 : 1)
