import Foundation

func readWAV(_ path: String) -> [Float] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let bytes = [UInt8](data)
    guard bytes.count > 44 else { return [] }
    var cursor = 12
    var start = 44
    var length = bytes.count - 44
    while cursor + 8 <= bytes.count {
        let id = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
        let size = Int(bytes[cursor + 4]) | Int(bytes[cursor + 5]) << 8
            | Int(bytes[cursor + 6]) << 16 | Int(bytes[cursor + 7]) << 24
        if id == "data" {
            start = cursor + 8
            length = size
            break
        }
        cursor += 8 + size + (size % 2)
    }
    var samples: [Float] = []
    samples.reserveCapacity(length / 2)
    var index = start
    while index + 1 < min(start + length, bytes.count) {
        let raw = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
        samples.append(Float(raw) / 32768)
        index += 2
    }
    return samples
}

final class TimingBackend: DecodeBackend {
    private let inner = WhisperBackend()
    private let lock = NSLock()
    private(set) var windows: [Double] = []
    private(set) var costs: [Double] = []

    func decode(
        samples: [Float],
        windowStart: Double,
        timeout: TimeInterval,
        temperatureFallback: Bool
    ) throws -> [SpokenWord] {
        let began = Date()
        let window = Double(samples.count) / Config.streamSampleRate
        defer {
            lock.lock()
            windows.append(window)
            costs.append(Date().timeIntervalSince(began))
            lock.unlock()
        }
        return try inner.decode(
            samples: samples,
            windowStart: windowStart,
            timeout: timeout,
            temperatureFallback: temperatureFallback
        )
    }

    func abort() {
        inner.abort()
    }
}

struct Emission {
    let audioSeconds: Double
    let wallSeconds: Double
    let text: String
}

func replay(
    samples: [Float],
    tuning: WindowedDecoder.Tuning,
    speed: Double
) -> (
    emissions: [Emission],
    tail: String,
    steps: Int,
    wall: Double,
    feed: Double,
    backend: TimingBackend
) {
    let buffer = StreamBuffer(sampleRate: Config.streamSampleRate)
    let backend = TimingBackend()
    let decoder = WindowedDecoder(source: buffer, backend: backend, tuning: tuning)
    let started = Date()
    var emissions: [Emission] = []
    let lock = NSLock()

    decoder.onDelta = { [weak decoder] delta in
        lock.lock()
        emissions.append(Emission(
            audioSeconds: decoder?.committedSeconds ?? buffer.duration,
            wallSeconds: Date().timeIntervalSince(started),
            text: delta
        ))
        lock.unlock()
    }
    decoder.start()

    let chunk = Int(Config.streamSampleRate * 0.1)
    var offset = 0
    while offset < samples.count {
        let end = min(offset + chunk, samples.count)
        buffer.append(Array(samples[offset..<end]))
        offset = end
        let audioElapsed = Double(offset) / Config.streamSampleRate
        let target = started.addingTimeInterval(audioElapsed / speed)
        while Date() < target {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    let feed = Date().timeIntervalSince(started)
    var tail = ""
    var settled = false
    decoder.finish { text, _ in
        tail = text
        settled = true
    }
    let limit = Date().addingTimeInterval(120)
    while !settled, Date() < limit {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    lock.lock()
    let captured = emissions
    lock.unlock()
    return (captured, tail, decoder.stepCount, Date().timeIntervalSince(started), feed, backend)
}

func percentile(_ values: [Double], _ share: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * share).rounded(.down))))
    return sorted[index]
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("uso: bench <audio.wav> [agreementSteps] [stepSeconds]")
    exit(2)
}
let samples = readWAV(arguments[1])
guard !samples.isEmpty else {
    print("audio vazio ou ilegível: \(arguments[1])")
    exit(2)
}

var tuning = WindowedDecoder.Tuning.standard
if arguments.count > 2, let steps = Int(arguments[2]) { tuning.agreementSteps = steps }
if arguments.count > 3, let step = Double(arguments[3]) { tuning.stepSeconds = step }

let audioSeconds = Double(samples.count) / Config.streamSampleRate
let run = replay(samples: samples, tuning: tuning, speed: 1.0)

let lags = run.emissions.map { $0.wallSeconds - $0.audioSeconds }
let text = (run.emissions.map(\.text) + [run.tail])
    .filter { !$0.isEmpty }
    .joined(separator: " ")

print("audio: \(String(format: "%.1f", audioSeconds))s")
print("agreementSteps=\(tuning.agreementSteps) stepSeconds=\(tuning.stepSeconds)")
print("passos: \(run.steps)")
print("emissoes: \(run.emissions.count)")
print("atraso medio: \(String(format: "%.2f", lags.reduce(0, +) / Double(max(lags.count, 1))))s")
print("atraso p90: \(String(format: "%.2f", percentile(lags, 0.9)))s")
print("atraso max: \(String(format: "%.2f", lags.max() ?? 0))s")
let windows = run.backend.windows
let costs = run.backend.costs
if !windows.isEmpty {
    print("janela media: \(String(format: "%.1f", windows.reduce(0, +) / Double(windows.count)))s")
    print("janela max: \(String(format: "%.1f", windows.max() ?? 0))s")
    print("decode medio: \(String(format: "%.2f", costs.reduce(0, +) / Double(costs.count)))s")
    print("decode p90: \(String(format: "%.2f", percentile(costs, 0.9)))s")
    print("decode max: \(String(format: "%.2f", costs.max() ?? 0))s")
}
print("alimentacao: \(String(format: "%.2f", run.feed))s (audio \(String(format: "%.1f", audioSeconds))s)")
print("cauda apos parar: \(String(format: "%.2f", run.wall - run.feed))s")
print("palavras: \(text.split(whereSeparator: \.isWhitespace).count)")
print("---")
print(text)
if let target = ProcessInfo.processInfo.environment["BENCH_OUTPUT"] {
    try? text.write(toFile: target, atomically: true, encoding: .utf8)
}
