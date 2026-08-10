import Foundation

enum TranscriberError: LocalizedError {
    case dependencyMissing(String)
    case convertFailed(String)
    case whisperFailed(String)
    case timedOut
    case cancelled
    case empty

    var errorDescription: String? {
        switch self {
        case .dependencyMissing(let detail): return detail
        case .convertFailed(let detail): return "conversão falhou: \(detail)"
        case .whisperFailed(let detail): return "whisper falhou: \(detail)"
        case .timedOut: return "transcrição excedeu o tempo limite"
        case .cancelled: return "transcrição cancelada"
        case .empty: return "nada foi transcrito"
        }
    }
}

final class Transcriber {
    private let queue = DispatchQueue(label: "ai.garime.whisper.transcriber")
    private let runner = ProcessRunner()

    func transcribe(
        source: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        queue.async {
            self.runner.reset()
            let result = self.run(source: source)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func cancel() {
        runner.cancel()
    }

    private func run(source: URL) -> Result<String, Error> {
        if let missing = Preflight.missingDependency() {
            return .failure(TranscriberError.dependencyMissing(missing))
        }

        let wav = source.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: wav) }

        do {
            let convert = try runner.run(
                Config.ffmpegBinary,
                [
                    "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                    "-i", source.path,
                    "-ac", "1",
                    "-ar", "16000",
                    "-c:a", "pcm_s16le",
                    wav.path,
                ],
                timeout: Config.transcribeTimeout
            )
            if convert.cancelled {
                return .failure(TranscriberError.cancelled)
            }
            if convert.timedOut {
                return .failure(TranscriberError.timedOut)
            }
            guard convert.status == 0 else {
                return .failure(TranscriberError.convertFailed(convert.trimmedError))
            }

            let transcribe = try runner.run(
                Config.whisperBinary,
                [
                    "-m", Config.modelPath,
                    "-f", wav.path,
                    "-l", Config.language,
                    "-nt",
                    "-np",
                ],
                timeout: Config.transcribeTimeout
            )
            if transcribe.cancelled {
                return .failure(TranscriberError.cancelled)
            }
            if transcribe.timedOut {
                return .failure(TranscriberError.timedOut)
            }
            guard transcribe.status == 0 else {
                return .failure(TranscriberError.whisperFailed(transcribe.trimmedError))
            }

            let text = Transcriber.clean(transcribe.output)
            return text.isEmpty ? .failure(TranscriberError.empty) : .success(text)
        } catch {
            return .failure(TranscriberError.whisperFailed(error.localizedDescription))
        }
    }

    static func clean(_ raw: String) -> String {
        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.hasPrefix("[") && line.hasSuffix("]") { return false }
                if line.hasPrefix("(") && line.hasSuffix(")") { return false }
                return true
            }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
