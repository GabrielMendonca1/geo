import AVFoundation
import Foundation

enum MeetingState {
    case idle
    case recording(started: Date, directory: URL)
    case transcribing(directory: URL)
    case done(directory: URL)
    case failed(String)
}

final class MeetingController {
    private let recorder = Recorder()
    private let runner = ProcessRunner()
    private let queue = DispatchQueue(label: "ai.garime.whisper.meeting")
    private var elapsedTimer: Timer?

    private(set) var state: MeetingState = .idle
    var onChange: (() -> Void)?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    init() {
        recorder.onRouteChange = { [weak self] in self?.stop() }
    }

    func begin() {
        switch state {
        case .recording, .transcribing:
            return
        default:
            break
        }
        Recorder.microphoneAuthorized { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.state = .failed(RecorderError.microphoneDenied.localizedDescription)
                self.onChange?()
                return
            }
            if case .recording = self.state { return }
            do {
                try self.recorder.start()
            } catch {
                self.state = .failed(error.localizedDescription)
                self.onChange?()
                return
            }
            let directory = MeetingArchive.directory(
                root: Config.meetingsDirectory,
                date: Date(),
                label: Config.meetingLabel
            )
            self.state = .recording(started: Date(), directory: directory)
            self.startElapsedTimer()
            self.onChange?()
        }
    }

    func stop() {
        guard case .recording(_, let directory) = state else { return }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard let capture = recorder.stop() else {
            state = .idle
            onChange?()
            return
        }
        guard capture.duration >= Config.meetingMinSeconds else {
            try? FileManager.default.removeItem(at: capture.url)
            state = .idle
            onChange?()
            return
        }
        state = .transcribing(directory: directory)
        onChange?()
        queue.async { [weak self] in
            guard let self else { return }
            self.runner.reset()
            let result = MeetingArchive.produce(
                capture: capture.url,
                into: directory,
                runner: self.runner
            )
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.state = .done(directory: directory)
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
                self.onChange?()
            }
        }
    }

    func abort() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recorder.abort()
        runner.cancel()
    }

    func elapsedMinutes(reference: Date = Date()) -> Int {
        guard case .recording(let started, _) = state else { return 0 }
        return max(0, Int(reference.timeIntervalSince(started) / 60))
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: Config.meetingElapsedRefresh, repeats: true) { [weak self] _ in
            self?.onChange?()
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }
}
