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
        return parse(raw) {
            if kill($0, 0) == 0 { return true }
            return errno == EPERM
        }
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
    private let queue = DispatchQueue(label: "ai.garime.hub.call")
    private var timer: Timer?
    private var watcher: PathWatcher?
    private var busy = false
    private var holdsFeedbackCapture = false
    private var absentPolls = 0

    private(set) var state: CallState = .idle
    var onChange: (() -> Void)?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func start() {
        guard watcher == nil else { return }
        poll()
        let directory = (Config.recStatePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stateFile = (Config.recStatePath as NSString).lastPathComponent
        let fileWatcher = PathWatcher(
            paths: [directory],
            accepts: { ($0 as NSString).lastPathComponent == stateFile }
        ) { [weak self] in self?.poll() }
        fileWatcher.start()
        watcher = fileWatcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        setLivenessTimer(active: false)
        runner.cancel()
        if RecProbe.read(path: Config.recStatePath)?.active == true {
            setFeedbackCapture(active: true)
        }
    }

    private func setLivenessTimer(active: Bool) {
        guard active != (timer != nil) else { return }
        guard active else {
            timer?.invalidate()
            timer = nil
            return
        }
        let ticker = Timer(timeInterval: Config.callLivenessInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        ticker.tolerance = Config.slowPollTolerance
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    @discardableResult
    func preflightFeedback() -> Bool {
        guard let probe = RecProbe.read(path: Config.recStatePath), probe.active else {
            return !holdsFeedbackCapture
        }
        setFeedbackCapture(active: true)
        if !busy, !isRecording {
            state = .recording(directory: probe.directory)
            onChange?()
        }
        return false
    }

    func poll() {
        guard !busy else { return }
        let probe = RecProbe.read(path: Config.recStatePath)
        let next: CallState
        if let probe, probe.active {
            absentPolls = 0
            setFeedbackCapture(active: true)
            next = .recording(directory: probe.directory)
        } else if probe != nil || absentPolls >= 1 {
            absentPolls = 0
            setFeedbackCapture(active: false)
            switch state {
            case .recording, .stopping:
                next = .idle
            default:
                next = state
            }
        } else {
            absentPolls += 1
            next = state
        }
        setLivenessTimer(active: probe?.active == true)
        if next != state {
            state = next
            onChange?()
        }
    }

    func begin() {
        guard !busy, !isRecording else { return }
        setFeedbackCapture(active: true)
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
                let probe = RecProbe.read(path: Config.recStatePath)
                if let probe, probe.active {
                    self.setFeedbackCapture(active: true)
                    self.state = .recording(directory: probe.directory)
                } else {
                    self.setFeedbackCapture(active: false)
                    let detail = outcome?.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state = .failed(detail?.isEmpty == false ? String(detail!.prefix(120)) : "rec.sh não iniciou")
                    self.playFeedback(.error)
                }
                self.onChange?()
            }
        }
    }

    func finish() {
        guard case .recording(let directory) = state, !busy else { return }
        guard RecProbe.read(path: Config.recStatePath)?.active == true else {
            setFeedbackCapture(active: false)
            state = .failed("nenhuma call em gravação")
            playFeedback(.cancelled)
            onChange?()
            return
        }
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
                let stillActive = RecProbe.read(path: Config.recStatePath)?.active == true
                self.setFeedbackCapture(active: stillActive)
                let reportedNothing = outcome?.output.localizedCaseInsensitiveContains("NADA GRAVANDO") == true
                if let outcome, outcome.status == 0, !reportedNothing, !stillActive {
                    self.state = .done(directory: directory)
                    self.playFeedback(.completed)
                } else if reportedNothing {
                    self.state = .failed("nenhuma call em gravação")
                    self.playFeedback(.cancelled)
                } else {
                    self.state = .failed("rec.sh stop falhou")
                    self.playFeedback(.error)
                }
                self.onChange?()
            }
        }
    }

    private func playFeedback(_ cue: FeedbackCue) {
        guard preflightFeedback() else { return }
        SoundFeedback.shared.play(cue)
    }

    private func setFeedbackCapture(active: Bool) {
        guard active != holdsFeedbackCapture else { return }
        holdsFeedbackCapture = active
        if active {
            SoundFeedback.shared.beginCapture("call")
        } else {
            SoundFeedback.shared.endCapture("call")
        }
    }
}
