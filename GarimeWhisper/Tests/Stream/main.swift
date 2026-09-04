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

final class RecordingSink: TextSink {
    private let lock = NSLock()
    private var storage: [(text: String, at: Date)] = []

    func emit(_ text: String) -> Bool {
        lock.lock()
        storage.append((text, Date()))
        lock.unlock()
        return true
    }

    var entries: [(text: String, at: Date)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var joined: String { entries.map(\.text).joined() }
    var count: Int { entries.count }
}

final class OpenGate: FocusGate {
    var isAvailable: Bool { true }
    var isSecure: Bool { false }
    func anchor() -> Bool { true }
    func stillFocused() -> Bool { true }
    func release() {}
}

final class Flag {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

func readWAV(_ path: String) -> [Float] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 44 else {
        return []
    }
    var offset = 12
    while offset + 8 <= data.count {
        let identifier = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
        let size = data[(offset + 4)..<(offset + 8)].withUnsafeBytes { raw in
            Int(raw.loadUnaligned(as: UInt32.self).littleEndian)
        }
        let payload = offset + 8
        if identifier == "data" {
            let upper = min(data.count, payload + size)
            var samples: [Float] = []
            samples.reserveCapacity((upper - payload) / 2)
            var index = payload
            while index + 1 < upper {
                let value = data[index..<(index + 2)].withUnsafeBytes { raw in
                    Int16(bitPattern: raw.loadUnaligned(as: UInt16.self).littleEndian)
                }
                samples.append(Float(value) / 32768)
                index += 2
            }
            return samples
        }
        offset = payload + size + (size % 2)
    }
    return []
}

func pumpUntil(_ flag: Flag, limit: TimeInterval) {
    let deadline = Date().addingTimeInterval(limit)
    while !flag.isSet, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

func tokens(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace)
        .map { Stabilizer.normalize(String($0)) }
        .filter { !$0.isEmpty }
}

struct Run {
    let deltasBeforeFlush: Int
    let emissions: [String]
    let transcript: String
    let typed: String
    let tail: String
    let failed: Bool
    let seconds: Double
}

func iterate(samples: [Float], generation: Int) -> Run {
    let buffer = StreamBuffer(sampleRate: Config.streamSampleRate)
    let sink = RecordingSink()
    let session = DictationSession(generation: generation, sink: sink, gate: OpenGate())
    _ = session.begin()
    let decoder = WindowedDecoder(source: buffer, backend: WhisperBackend(), tuning: .standard)
    decoder.onDelta = { delta in
        _ = session.ingest(delta, generation: generation)
    }

    let began = Date()
    decoder.start()

    let slice = Int(Config.streamSampleRate / 10)
    let fed = Flag()
    DispatchQueue.global().async {
        var index = 0
        while index < samples.count {
            let upper = min(samples.count, index + slice)
            buffer.append(Array(samples[index..<upper]))
            index = upper
            Thread.sleep(forTimeInterval: 0.1)
        }
        fed.set()
    }
    pumpUntil(fed, limit: Double(samples.count) / Config.streamSampleRate + 30)

    let beforeFlush = sink.count
    let done = Flag()
    var tail = ""
    var failed = false
    decoder.finish { value, reported in
        tail = value
        failed = reported
        _ = session.finish(tail: value, generation: generation)
        done.set()
    }
    pumpUntil(done, limit: Config.flushTimeout + 30)
    decoder.cancel()

    return Run(
        deltasBeforeFlush: beforeFlush,
        emissions: sink.entries.map(\.text),
        transcript: session.transcript,
        typed: session.typedText,
        tail: tail,
        failed: failed,
        seconds: Date().timeIntervalSince(began)
    )
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("  FAIL usage: stream <wav> <iterations> <ground truth>")
    exit(1)
}
let audio = readWAV(arguments[1])
let iterations = Int(arguments[2]) ?? 5
let truth = tokens(arguments[3])

check(!audio.isEmpty, "the pt-BR sample loaded [\(audio.count) samples]")
check(
    Set(truth).count == truth.count,
    "the ground truth has no repeated word, so counting is meaningful"
)
let seconds = Double(audio.count) / Config.streamSampleRate
check(seconds > 8, "the sample is long enough for several windows [\(String(format: "%.1f", seconds))s]")

for index in 0..<iterations {
    print("== fake sink e2e: iteration \(index + 1)/\(iterations) ==")
    let run = iterate(samples: audio, generation: index + 1)
    print("  time \(String(format: "%.1f", run.seconds))s   deltas \(run.emissions.count) (\(run.deltasBeforeFlush) before flush)")
    print("  text \(run.transcript)")

    check(run.deltasBeforeFlush >= 3, "at least three deltas arrive before the flush [\(run.deltasBeforeFlush)]")
    check(!run.failed, "the flush was accepted by the guard")
    equal(run.emissions.joined(), run.transcript, "every emitted delta concatenates to the transcript")
    equal(run.typed, run.transcript, "the sink received the whole transcript")

    var monotone = true
    var prefix = ""
    for piece in run.emissions {
        prefix += piece
        if !run.transcript.hasPrefix(prefix) { monotone = false }
    }
    check(monotone, "delivery is append-only, nothing is rewritten or deleted")

    check(
        FlushGuard.rejection(tail: run.tail, windowSeconds: seconds) == nil,
        "the flush output passes the degenerate-tail validator"
    )

    let produced = tokens(run.transcript)
    var duplicated: [String] = []
    var missing: [String] = []
    for word in truth {
        let occurrences = produced.filter { $0 == word }.count
        if occurrences > 1 { duplicated.append(word) }
        if occurrences == 0 { missing.append(word) }
    }
    equal(duplicated, [], "no word is duplicated versus the ground truth")
    equal(missing, [], "no word is lost versus the ground truth")
}

print("")
print("stream passed: \(passes)   failed: \(failures)")
exit(failures == 0 ? 0 : 1)
