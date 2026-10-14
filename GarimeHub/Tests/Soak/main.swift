import Darwin
import Foundation

func readWAV(_ path: String) -> [Float] {
    guard let data = FileManager.default.contents(atPath: path), data.count > 44 else { return [] }
    let bytes = [UInt8](data)
    var cursor = 12
    var start = 44
    var length = bytes.count - 44
    while cursor + 8 <= bytes.count {
        let id = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
        let size = Int(bytes[cursor + 4]) | Int(bytes[cursor + 5]) << 8
            | Int(bytes[cursor + 6]) << 16 | Int(bytes[cursor + 7]) << 24
        if id == "data" { start = cursor + 8; length = size; break }
        cursor += 8 + size + (size % 2)
    }
    var samples: [Float] = []
    var index = start
    while index + 1 < min(start + length, bytes.count) {
        samples.append(Float(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)) / 32768)
        index += 2
    }
    return samples
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

final class CollectingSink: TextSink {
    var text = ""
    func emit(_ chunk: String) -> Bool { text += chunk; return true }
}

final class OpenGate: FocusGate {
    var isAvailable: Bool { true }
    var isSecure: Bool { false }
    func anchor() -> Bool { true }
    func stillFocused() -> Bool { true }
    func release() {}
}

var failures = 0
func check(_ ok: Bool, _ label: String) {
    print(ok ? "  ok   \(label)" : "  FAIL \(label)")
    if !ok { failures += 1 }
}

let samples = readWAV(CommandLine.arguments[1])
let sessions = Int(CommandLine.arguments[2]) ?? 4
print("audio \(String(format: "%.1f", Double(samples.count) / Config.streamSampleRate))s × \(sessions) sessões")

weak var lastDecoder: WindowedDecoder?
weak var lastSession: DictationSession?
weak var lastBuffer: StreamBuffer?
var footprints: [Double] = []
var firstWordLags: [Double] = []

for round in 1...sessions {
    autoreleasepool {
        let buffer = StreamBuffer(sampleRate: Config.streamSampleRate)
        let sink = CollectingSink()
        let session = DictationSession(generation: round, sink: sink, gate: OpenGate())
        _ = session.begin()
        let decoder = WindowedDecoder(source: buffer, backend: WhisperBackend(), tuning: .standard)
        let started = Date()
        var firstWord: Double?
        decoder.onDelta = { [weak session] delta in
            if firstWord == nil { firstWord = Date().timeIntervalSince(started) }
            _ = session?.ingest(delta, generation: round)
        }
        decoder.start()
        let chunk = Int(Config.streamSampleRate * 0.1)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            buffer.append(Array(samples[offset..<end]))
            offset = end
            let target = started.addingTimeInterval(Double(offset) / Config.streamSampleRate)
            while Date() < target { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }
        var settled = false
        decoder.finish { tail, _ in
            _ = session.finish(tail: tail, generation: round)
            settled = true
        }
        let limit = Date().addingTimeInterval(120)
        while !settled, Date() < limit { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        let words = sink.text.split(whereSeparator: \.isWhitespace).count
        firstWordLags.append(firstWord ?? -1)
        print("  sessão \(round): \(words) palavras, primeira em \(String(format: "%.1f", firstWord ?? -1))s, footprint \(String(format: "%.1f", footprintMB())) MB")
        lastDecoder = decoder
        lastSession = session
        lastBuffer = buffer
    }
    for _ in 0..<10 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    footprints.append(footprintMB())
}

Thread.sleep(forTimeInterval: 0.5)
check(lastDecoder == nil, "decoder is released after the session")
check(lastSession == nil, "dictation session is released")
check(lastBuffer == nil, "audio buffer is released")
let growth = (footprints.last ?? 0) - (footprints.dropFirst().first ?? footprints.first ?? 0)
check(growth < 3, "footprint does not grow across sessions (+\(String(format: "%.1f", growth)) MB after the first)")

let leaks = Process()
leaks.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
leaks.arguments = [String(getpid())]
let pipe = Pipe()
leaks.standardOutput = pipe
leaks.standardError = FileHandle.nullDevice
try? leaks.run()
let report = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
leaks.waitUntilExit()
let line = report.split(separator: "\n").first { $0.contains("leaks for") }.map(String.init) ?? "?"
print("  leaks: \(line)")
check(line.contains(": 0 leaks"), "no leaked allocations")
if !line.contains(": 0 leaks") {
    print(report.split(separator: "\n").prefix(40).joined(separator: "\n"))
}
exit(failures == 0 ? 0 : 1)
