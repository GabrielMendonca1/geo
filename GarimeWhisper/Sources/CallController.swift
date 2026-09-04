import Foundation

struct RecState: Equatable {
    let directory: String
    let pid: Int32
    let active: Bool
}

enum RecProbe {
    static func parse(_ raw: String, liveness: (Int32) -> Bool) -> RecState? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, let pid = Int32(lines[1]), !lines[0].isEmpty else { return nil }
        return RecState(directory: lines[0], pid: pid, active: liveness(pid))
    }

    static func read(path: String) -> RecState? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(raw) { kill($0, 0) == 0 }
    }
}

enum CallState: Equatable {
    case idle
    case recording(directory: String)
    case stopping
    case done(directory: String)
    case failed(String)
}

final class CallController {
    private let runner = ProcessRunner()
    private let queue = DispatchQueue(label: "ai.garime.whisper.call")
    private var timer: Timer?
    private var busy = false

    private(set) var state: CallState = .idle
    var onChange: (() -> Void)?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func start() {
        poll()
        let ticker = Timer(timeInterval: Config.callPollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        runner.cancel()
    }

    func poll() {
        guard !busy else { return }
        let probe = RecProbe.read(path: Config.recStatePath)
        let next: CallState
        if let probe, probe.active {
            next = .recording(directory: probe.directory)
        } else {
            switch state {
            case .recording, .stopping:
                next = .idle
            default:
                next = state
            }
        }
        if next != state {
            state = next
            onChange?()
        }
    }

    func begin() {
        guard !busy, !isRecording else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            self.runner.reset()
            let outcome = try? self.runner.run(
                "/usr/bin/env",
                [
                    "PATH=" + Config.recPath,
                    Config.recScript,
                    "start", "call", Config.meetingLabel,
                ],
                timeout: Config.callStartTimeout
            )
            DispatchQueue.main.async {
                self.busy = false
                if let outcome, outcome.status == 0, outcome.output.contains("REC_STARTED") {
                    let probe = RecProbe.read(path: Config.recStatePath)
                    self.state = .recording(directory: probe?.directory ?? "")
                } else {
                    let detail = outcome?.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state = .failed(detail?.isEmpty == false ? String(detail!.prefix(120)) : "rec.sh não iniciou")
                }
                self.onChange?()
            }
        }
    }

    func finish() {
        guard case .recording(let directory) = state, !busy else { return }
        busy = true
        state = .stopping
        onChange?()
        queue.async { [weak self] in
            guard let self else { return }
            self.runner.reset()
            let outcome = try? self.runner.run(
                "/usr/bin/env",
                [
                    "PATH=" + Config.recPath,
                    Config.recScript,
                    "stop",
                ],
                timeout: Config.callStopTimeout
            )
            DispatchQueue.main.async {
                self.busy = false
                if let outcome, outcome.status == 0 {
                    self.state = .done(directory: directory)
                } else {
                    self.state = .failed("rec.sh stop falhou")
                }
                self.onChange?()
            }
        }
    }
}
