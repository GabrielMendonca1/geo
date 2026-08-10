import Foundation

enum Config {
    static let whisperBinary = ProcessInfo.processInfo.environment["HARNESS_WHISPER"] ?? "/usr/bin/true"
    static let ffmpegBinary = ProcessInfo.processInfo.environment["HARNESS_FFMPEG"] ?? "/usr/bin/true"
    static let modelPath = "/dev/null"
    static let language = "pt"
    static let transcribeTimeout = TimeInterval(
        ProcessInfo.processInfo.environment["HARNESS_TIMEOUT"] ?? ""
    ) ?? 2
}

enum Preflight {
    static func missingDependency() -> String? { nil }
}

func drive(cancelAfter: TimeInterval?) -> (label: String, elapsed: TimeInterval) {
    let transcriber = Transcriber()
    let source = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("harness-\(UUID().uuidString).caf")
    FileManager.default.createFile(atPath: source.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: source) }

    var label: String?
    let started = Date()

    transcriber.transcribe(source: source) { result in
        switch result {
        case .success(let text):
            label = "success:\(text)"
        case .failure(let error):
            label = String(describing: error)
        }
    }

    if let cancelAfter {
        DispatchQueue.global().asyncAfter(deadline: .now() + cancelAfter) {
            transcriber.cancel()
        }
    }

    let limit = Date().addingTimeInterval(40)
    while label == nil, Date() < limit {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return (label ?? "hung", Date().timeIntervalSince(started))
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "timeout"
let outcome = drive(cancelAfter: mode == "cancel" ? 0.5 : nil)
print("\(outcome.label) \(String(format: "%.2f", outcome.elapsed))")
