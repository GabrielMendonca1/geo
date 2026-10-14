import Foundation

final class WhisperBackend: DecodeBackend {
    private let runner = ProcessRunner()
    private let directory: URL

    init() {
        directory = URL(fileURLWithPath: Config.workDirectory)
    }

    func decode(
        samples: [Float],
        windowStart: Double,
        timeout: TimeInterval,
        temperatureFallback: Bool
    ) throws -> [SpokenWord] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = directory.appendingPathComponent("step-\(UUID().uuidString)")
        let wav = stem.appendingPathExtension("wav")
        let json = stem.appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: json)
        }

        try StreamBuffer.writeWAV(samples, sampleRate: Config.streamSampleRate, to: wav)

        var arguments = [
            "-m", Config.modelPath,
            "-f", wav.path,
            "-l", Config.language,
            "-np",
            "-bs", "1",
            "-ml", "1",
            "-sow",
            "-oj",
            "-of", stem.path,
        ]
        if !temperatureFallback {
            arguments.append("-nf")
        }

        runner.reset()
        let outcome = try runner.run(Config.whisperBinary, arguments, timeout: timeout)
        if outcome.cancelled { throw DecodeError.failed("cancelado") }
        if outcome.timedOut { throw DecodeError.failed("tempo limite") }
        guard outcome.status == 0 else { throw DecodeError.failed(outcome.trimmedError) }

        return try WhisperBackend.parse(url: json, windowStart: windowStart)
    }

    func abort() {
        runner.cancel()
    }

    static func parse(url: URL, windowStart: Double) throws -> [SpokenWord] {
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data)
        guard
            let dictionary = root as? [String: Any],
            let segments = dictionary["transcription"] as? [[String: Any]]
        else {
            throw DecodeError.failed("json inesperado")
        }
        return segments.compactMap { segment in
            guard
                let offsets = segment["offsets"] as? [String: Any],
                let from = offsets["from"] as? Int,
                let to = offsets["to"] as? Int,
                let text = segment["text"] as? String
            else { return nil }
            let word = SpokenWord(
                text: text,
                start: windowStart + Double(from) / 1000,
                end: windowStart + Double(to) / 1000
            )
            return word.text.isEmpty ? nil : word
        }
    }
}
