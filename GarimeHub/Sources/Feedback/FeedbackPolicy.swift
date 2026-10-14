import Foundation

enum FeedbackDecision: Equatable {
    case play
    case disabled
    case muted
    case suppressedCapture
    case rateLimited
    case coalesced

    var isAudible: Bool { self == .play }
}

struct FeedbackCaptureGate {
    private var counts: [String: Int] = [:]

    var isActive: Bool { !counts.isEmpty }

    var reasons: [String] { counts.keys.sorted() }

    func depth(_ key: String) -> Int { counts[FeedbackCaptureGate.normalize(key)] ?? 0 }

    @discardableResult
    mutating func begin(_ key: String) -> Bool {
        let name = FeedbackCaptureGate.normalize(key)
        let wasActive = isActive
        counts[name] = (counts[name] ?? 0) + 1
        return !wasActive
    }

    @discardableResult
    mutating func end(_ key: String) -> Bool {
        let name = FeedbackCaptureGate.normalize(key)
        guard let current = counts[name] else { return false }
        if current <= 1 {
            counts.removeValue(forKey: name)
        } else {
            counts[name] = current - 1
        }
        return !isActive
    }

    @discardableResult
    mutating func reset() -> Bool {
        let wasActive = isActive
        counts.removeAll()
        return wasActive
    }

    static func normalize(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unnamed" : trimmed
    }
}

struct FeedbackGate {
    var enabled: Bool
    var volume: Double

    private var capture = FeedbackCaptureGate()
    private var lastPlayback: TimeInterval?
    private var lastByCue: [FeedbackCue: TimeInterval] = [:]

    init(enabled: Bool = true, volume: Double = FeedbackVolume.fallback) {
        self.enabled = enabled
        self.volume = volume
    }

    var isCaptureActive: Bool { capture.isActive }

    var captureReasons: [String] { capture.reasons }

    func captureDepth(_ key: String) -> Int { capture.depth(key) }

    @discardableResult
    mutating func beginCapture(_ key: String) -> Bool {
        capture.begin(key)
    }

    @discardableResult
    mutating func endCapture(_ key: String) -> Bool {
        capture.end(key)
    }

    @discardableResult
    mutating func resetCapture() -> Bool {
        capture.reset()
    }

    mutating func forgetTimings() {
        lastPlayback = nil
        lastByCue.removeAll()
    }

    mutating func evaluate(cue: FeedbackCue, now: TimeInterval) -> FeedbackDecision {
        guard enabled else { return .disabled }
        if capture.isActive { return .suppressedCapture }
        if FeedbackVolume.isSilent(volume) { return .muted }
        guard now.isFinite else { return .rateLimited }

        if let last = lastByCue[cue] {
            if now < last {
                forgetTimings()
            } else if now - last < cue.coalesceWindow {
                return .coalesced
            }
        }

        if cue.priority == .ambient, let last = lastPlayback, now >= last,
           now - last < FeedbackTiming.globalMinimumGap {
            return .rateLimited
        }

        lastByCue[cue] = now
        lastPlayback = now
        return .play
    }
}
