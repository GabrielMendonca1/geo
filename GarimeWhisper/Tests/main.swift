import Foundation

enum Config {
    static let whisperBinary = ProcessInfo.processInfo.environment["HARNESS_WHISPER"] ?? "/usr/bin/true"
    static let ffmpegBinary = ProcessInfo.processInfo.environment["HARNESS_FFMPEG"] ?? "/usr/bin/true"
    static let modelPath = "/dev/null"
    static let language = "pt"
    static let transcribeTimeout = TimeInterval(
        ProcessInfo.processInfo.environment["HARNESS_TIMEOUT"] ?? ""
    ) ?? 2
    static let meetingConvertTimeout = transcribeTimeout
    static let meetingTranscribeTimeout = transcribeTimeout
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

if mode == "meeting" {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("harness-meeting-\(UUID().uuidString)")
    let capture = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("harness-\(UUID().uuidString).caf")
    FileManager.default.createFile(atPath: capture.path, contents: Data("caf".utf8))
    let result = MeetingArchive.produce(capture: capture, into: dir, runner: ProcessRunner())
    let fm = FileManager.default
    let wav = fm.fileExists(atPath: dir.appendingPathComponent("audio.wav").path)
    let rawGone = !fm.fileExists(atPath: dir.appendingPathComponent("audio.caf").path)
    let originalGone = !fm.fileExists(atPath: capture.path)
    let transcript = (try? String(
        contentsOf: dir.appendingPathComponent("transcript.txt"),
        encoding: .utf8
    ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    switch result {
    case .success:
        print("meeting-ok wav=\(wav) rawGone=\(rawGone) originalGone=\(originalGone) transcript=\(transcript)")
    case .failure(let error):
        print("meeting-fail wav=\(wav) originalGone=\(originalGone) error=\(error)")
    }
    try? fm.removeItem(at: dir)
    exit(0)
}

let outcome = drive(cancelAfter: mode == "cancel" ? 0.5 : nil)
print("\(outcome.label) \(String(format: "%.2f", outcome.elapsed))")
