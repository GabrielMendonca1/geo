import Foundation

protocol DecodeBackend: AnyObject {
    func decode(
        samples: [Float],
        windowStart: Double,
        timeout: TimeInterval,
        temperatureFallback: Bool
    ) throws -> [SpokenWord]
    func abort()
}

enum DecodeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let detail): return "decodificação falhou: \(detail)"
        }
    }
}

final class WindowedDecoder {
    struct Tuning {
        var stepSeconds: TimeInterval
        var backoffSeconds: Double
        var minWindowSeconds: Double
        var margin: Double
        var agreementSteps: Int
        var overlapWords: Int
        var maxWindowSeconds: Double
        var maxStepFailures: Int
        var giveUpSeconds: Double
        var stepTimeout: TimeInterval
        var flushTimeout: TimeInterval

        static let standard = Tuning(
            stepSeconds: Config.stepSeconds,
            backoffSeconds: Config.windowBackoffSeconds,
            minWindowSeconds: Config.minWindowSeconds,
            margin: Config.commitMarginSeconds,
            agreementSteps: Config.agreementSteps,
            overlapWords: Config.overlapDedupWords,
            maxWindowSeconds: Config.maxWindowSeconds,
            maxStepFailures: Config.maxStepFailures,
            giveUpSeconds: Config.uncommittedGiveUpSeconds,
            stepTimeout: Config.stepTimeout,
            flushTimeout: Config.flushTimeout
        )
    }

    var onDelta: ((String) -> Void)?
    var onStreamingLost: (() -> Void)?

    private let source: WindowSource
    private let backend: DecodeBackend
    private let tuning: Tuning
    private let queue = DispatchQueue(label: "ai.garime.whisper.decoder")
    private let lock = NSLock()

    private var stabilizer: Stabilizer
    private var running = false
    private var cancelled = false
    private var draining = false
    private var failures = 0
    private var stepCountStorage = 0

    init(source: WindowSource, backend: DecodeBackend, tuning: Tuning) {
        self.source = source
        self.backend = backend
        self.tuning = tuning
        self.stabilizer = Stabilizer(
            agreementSteps: tuning.agreementSteps,
            margin: tuning.margin,
            overlapWords: tuning.overlapWords
        )
    }

    var committedText: String {
        lock.lock()
        defer { lock.unlock() }
        return stabilizer.committedText
    }

    var stepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stepCountStorage
    }

    var committedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return stabilizer.commitTime
    }

    func start() {
        lock.lock()
        guard !running, !cancelled, !draining else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.tick() }
    }

    deinit {
        cancel()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        running = false
        lock.unlock()
        backend.abort()
    }

    func finish(completion: @escaping (String, Bool) -> Void) {
        lock.lock()
        let wasCancelled = cancelled
        running = false
        draining = true
        lock.unlock()
        backend.abort()

        guard !wasCancelled else {
            DispatchQueue.main.async { completion("", false) }
            return
        }
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion("", true) }
                return
            }
            let result = self.finalDecode()
            DispatchQueue.main.async { completion(result.tail, result.failed) }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func tick() {
        guard isRunning else { return }
        let now = source.duration
        let windowStart = currentWindowStart()
        guard now - windowStart >= tuning.minWindowSeconds else {
            reschedule(after: tuning.minWindowSeconds / 4)
            return
        }
        guard now - currentCommitTime() <= tuning.giveUpSeconds else {
            reschedule(after: tuning.stepSeconds)
            return
        }

        let began = Date()
        let samples = source.samples(from: windowStart, to: now)
        guard !samples.isEmpty else {
            reschedule(after: tuning.stepSeconds)
            return
        }

        do {
            let words = try backend.decode(
                samples: samples,
                windowStart: windowStart,
                timeout: tuning.stepTimeout,
                temperatureFallback: false
            )
            guard isRunning else { return }
            let degenerate = FlushGuard.stepRejection(
                tail: words.map(\.text).joined(separator: " "),
                windowSeconds: now - windowStart
            ) != nil
            let overgrown = now - windowStart >= tuning.maxWindowSeconds
            lock.lock()
            failures = 0
            stepCountStorage += 1
            let delta: String
            if degenerate {
                delta = ""
            } else if overgrown {
                delta = stabilizer.forceCommit(
                    words: words,
                    windowStart: windowStart,
                    cut: now - tuning.margin - tuning.stepSeconds
                )
            } else {
                delta = stabilizer.step(words: words, windowStart: windowStart, windowEnd: now)
            }
            lock.unlock()
            if !delta.isEmpty { emit(delta) }
        } catch {
            guard isRunning else { return }
            lock.lock()
            failures += 1
            let exhausted = failures >= tuning.maxStepFailures
            if exhausted { running = false }
            lock.unlock()
            if exhausted {
                let handler = onStreamingLost
                DispatchQueue.main.async { handler?() }
                return
            }
        }

        reschedule(after: max(tuning.stepSeconds - Date().timeIntervalSince(began), 0))
    }

    private func reschedule(after interval: TimeInterval) {
        guard isRunning else { return }
        guard interval > 0 else {
            queue.async { [weak self] in self?.tick() }
            return
        }
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in self?.tick() }
    }

    private func finalDecode() -> (tail: String, failed: Bool) {
        let now = source.duration
        let windowStart = currentWindowStart()
        guard now - windowStart > 0.05 else { return ("", false) }
        let samples = source.samples(from: windowStart, to: now)
        guard !samples.isEmpty else { return ("", false) }

        do {
            let words = try backend.decode(
                samples: samples,
                windowStart: windowStart,
                timeout: tuning.flushTimeout,
                temperatureFallback: true
            )
            let pending = Stabilizer
                .trimmingLeadingFragment(
                    words.filter { !$0.text.isEmpty },
                    windowStart: windowStart,
                    commitTime: currentCommitTime()
                )
                .map(\.text)
                .joined(separator: " ")
            guard !pending.isEmpty else { return ("", false) }
            guard FlushGuard.rejection(tail: pending, windowSeconds: now - windowStart) == nil else {
                return ("", true)
            }
            lock.lock()
            let delta = stabilizer.commitFinal(pending)
            lock.unlock()
            return (delta, false)
        } catch {
            return ("", true)
        }
    }

    private func currentCommitTime() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return stabilizer.commitTime
    }

    private func currentWindowStart() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return stabilizer.anchoredWindowStart(backoff: tuning.backoffSeconds)
    }

    private func emit(_ delta: String) {
        let handler = onDelta
        DispatchQueue.main.async { [weak self] in
            guard let self, self.deliversDeltas else { return }
            handler?(delta)
        }
    }

    private var deliversDeltas: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }
}
