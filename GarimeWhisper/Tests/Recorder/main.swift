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

func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    check(lhs == rhs, "\(label) [got: \(lhs)]")
}

func makeFormat(_ rate: Double) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
}

func makeTone(_ format: AVAudioFormat, frames: AVAudioFrameCount, phase: Int) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let channel = buffer.floatChannelData![0]
    for index in 0..<Int(frames) {
        let angle = 2.0 * Double.pi * 440.0 * Double(phase * Int(frames) + index) / format.sampleRate
        channel[index] = Float(sin(angle) * 0.4)
    }
    return buffer
}

let hardware = makeFormat(48000)
let target = makeFormat(Config.streamSampleRate)
let converter = AVAudioConverter(from: hardware, to: target)!
let scratch = Recorder.makeConversionBuffer(source: hardware, target: target, frames: 4096)

print("== recorder: the conversion scratch buffer is allocated once, outside the callback ==")
check(scratch != nil, "a reusable conversion buffer is prepared up front")
guard let scratch else {
    print("recorder passed: \(passes)   failed: \(failures + 1)")
    exit(1)
}
check(
    scratch.frameCapacity >= AVAudioFrameCount(4096 * Config.streamSampleRate / 48000),
    "the scratch buffer covers a full tap buffer at the target rate [\(scratch.frameCapacity)]"
)

print("== recorder: repeated conversions reuse the scratch buffer exactly ==")
do {
    let stream = StreamBuffer(sampleRate: Config.streamSampleRate)
    let rounds = 200
    var accepted = 0
    var previous = 0.0
    var monotone = true
    for index in 0..<rounds {
        let input = makeTone(hardware, frames: 4096, phase: index)
        if Recorder.forward(input, converter: converter, output: scratch, into: stream) { accepted += 1 }
        let now = stream.duration
        if now < previous { monotone = false }
        previous = now
    }
    equal(accepted, rounds, "every well formed buffer is converted")
    check(monotone, "the stream duration never goes backwards across reused conversions")

    let expected = Double(rounds * 4096) * Config.streamSampleRate / 48000
    let produced = Double(stream.samples(from: 0, to: 1000).count)
    check(
        abs(produced - expected) / expected < 0.01,
        "the resampled sample count matches the input duration [\(produced) vs \(expected)]"
    )
    check(
        stream.samples(from: 0, to: 1000).contains { $0 != 0 },
        "the converted audio is not silence"
    )
}

print("== recorder: a buffer from a reconfigured input is refused, never converted ==")
do {
    let stream = StreamBuffer(sampleRate: Config.streamSampleRate)
    let rogue = makeTone(makeFormat(44100), frames: 4096, phase: 0)
    let accepted = Recorder.forward(rogue, converter: converter, output: scratch, into: stream)
    check(!accepted, "a buffer whose format does not match the converter is refused")
    equal(stream.duration, 0, "a refused buffer contributes no samples")

    let good = makeTone(hardware, frames: 4096, phase: 0)
    check(
        Recorder.forward(good, converter: converter, output: scratch, into: stream),
        "the converter still works after refusing a mismatched buffer"
    )
    check(stream.duration > 0, "a matching buffer still lands after a refusal")
}

print("== recorder: an oversized buffer is refused instead of overflowing the scratch ==")
do {
    let stream = StreamBuffer(sampleRate: Config.streamSampleRate)
    let huge = makeTone(hardware, frames: 65536, phase: 0)
    let accepted = Recorder.forward(huge, converter: converter, output: scratch, into: stream)
    check(!accepted, "a buffer larger than the scratch capacity is refused")
    equal(stream.duration, 0, "an oversized buffer contributes no samples")
}

print("")
print("recorder passed: \(passes)   failed: \(failures)")
exit(failures == 0 ? 0 : 1)
