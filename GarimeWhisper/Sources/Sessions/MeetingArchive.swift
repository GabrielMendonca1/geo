import Foundation

enum MeetingArchiveError: LocalizedError {
    case createFailed(String)
    case convertFailed(String)
    case whisperFailed(String)
    case timedOut
    case cancelled
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .createFailed(let detail): return "não criou a pasta: \(detail)"
        case .convertFailed(let detail): return "conversão falhou: \(detail)"
        case .whisperFailed(let detail): return "whisper falhou: \(detail)"
        case .timedOut: return "transcrição excedeu o tempo limite"
        case .cancelled: return "transcrição cancelada"
        case .writeFailed(let detail): return "não gravou o transcript: \(detail)"
        }
    }
}

enum MeetingArchive {
    static func slugify(_ label: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let mapped = label.lowercased().map { $0.isWhitespace ? "-" : $0 }
        let slug = String(mapped.filter { allowed.contains($0) }.prefix(40))
        return slug.isEmpty ? "reuniao" : slug
    }

    static func directory(root: String, date: Date, label: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = formatter.string(from: date)
        let slug = slugify(label)
        let base = URL(fileURLWithPath: root).appendingPathComponent("\(stamp)-\(slug)")
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = URL(fileURLWithPath: root).appendingPathComponent("\(stamp)-\(slug)-\(counter)")
            counter += 1
        }
        return candidate
    }

    static func produce(capture: URL, into directory: URL, runner: ProcessRunner) -> Result<String, Error> {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(MeetingArchiveError.createFailed(error.localizedDescription))
        }

        let raw = directory.appendingPathComponent("audio.caf")
        do {
            try fm.moveItem(at: capture, to: raw)
        } catch {
            return .failure(MeetingArchiveError.createFailed(error.localizedDescription))
        }

        let wav = directory.appendingPathComponent("audio.wav")
        do {
            let convert = try runner.run(
                Config.ffmpegBinary,
                [
                    "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                    "-i", raw.path,
                    "-ac", "1",
                    "-ar", "16000",
                    "-c:a", "pcm_s16le",
                    wav.path,
                ],
                timeout: Config.meetingConvertTimeout
            )
            if convert.cancelled { return .failure(MeetingArchiveError.cancelled) }
            if convert.timedOut { return .failure(MeetingArchiveError.timedOut) }
            guard convert.status == 0 else {
                return .failure(MeetingArchiveError.convertFailed(convert.trimmedError))
            }
            try? fm.removeItem(at: raw)

            let transcribe = try runner.run(
                Config.whisperBinary,
                [
                    "-m", Config.modelPath,
                    "-f", wav.path,
                    "-l", Config.language,
                    "-nt",
                    "-np",
                ],
                timeout: Config.meetingTranscribeTimeout
            )
            if transcribe.cancelled { return .failure(MeetingArchiveError.cancelled) }
            if transcribe.timedOut { return .failure(MeetingArchiveError.timedOut) }
            guard transcribe.status == 0 else {
                return .failure(MeetingArchiveError.whisperFailed(transcribe.trimmedError))
            }

            let text = Transcriber.clean(transcribe.output)
            let transcript = directory.appendingPathComponent("transcript.txt")
            do {
                try (text + "\n").write(to: transcript, atomically: true, encoding: .utf8)
            } catch {
                return .failure(MeetingArchiveError.writeFailed(error.localizedDescription))
            }
            return .success(text)
        } catch {
            return .failure(MeetingArchiveError.whisperFailed(error.localizedDescription))
        }
    }
}
