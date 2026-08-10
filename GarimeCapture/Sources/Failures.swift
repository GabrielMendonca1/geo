import Foundation

let captureFailureLimit = 5
let retryBaseDelay = envDouble("GARIME_RETRY_BASE_DELAY", 15)
let retryMaxDelay = envDouble("GARIME_RETRY_MAX_DELAY", 300)
let failureRetentionSeconds: TimeInterval = 7 * 86_400

struct FailureRecord: Codable {
    var attempts: Int
    var updatedAt: TimeInterval
    var nextAttempt: TimeInterval
    var name: String
    var reason: String
}

func retryDelay(afterAttempts attempts: Int) -> TimeInterval {
    let raw = retryBaseDelay * pow(2, Double(max(0, attempts - 1)))
    return min(raw, retryMaxDelay)
}

final class FailureLedger {
    private let url: URL
    private let listURL: URL
    private var entries: [String: FailureRecord]

    init(url: URL, listURL: URL) {
        self.url = url
        self.listURL = listURL
        self.entries = Self.load(from: url)
    }

    func attempts(_ key: String) -> Int { entries[key]?.attempts ?? 0 }

    func isStranded(_ key: String) -> Bool { attempts(key) >= captureFailureLimit }

    func isBackingOff(_ key: String, now: Date) -> Bool {
        guard let record = entries[key] else { return false }
        return now.timeIntervalSince1970 < record.nextAttempt
    }

    @discardableResult
    func record(key: String, name: String, reason: String, now: Date) -> Int {
        let attempts = (entries[key]?.attempts ?? 0) + 1
        let stamp = now.timeIntervalSince1970
        entries[key] = FailureRecord(
            attempts: attempts,
            updatedAt: stamp,
            nextAttempt: stamp + retryDelay(afterAttempts: attempts),
            name: name,
            reason: reason
        )
        persist(now: now)
        return attempts
    }

    func clear(_ key: String) {
        guard entries.removeValue(forKey: key) != nil else { return }
        persist(now: Date())
    }

    private func persist(now: Date) {
        let cutoff = now.timeIntervalSince1970 - failureRetentionSeconds
        entries = entries.filter { $0.value.updatedAt >= cutoff }

        if !isForbiddenPath(url), let data = try? JSONEncoder().encode(entries) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }

        let names = Set(entries.values.filter { $0.attempts >= captureFailureLimit }.map(\.name)).sorted()
        guard !isForbiddenPath(listURL) else { return }
        if names.isEmpty {
            try? fm.removeItem(at: listURL)
            return
        }
        try? fm.createDirectory(at: listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((names.joined(separator: "\n") + "\n").utf8).write(to: listURL, options: .atomic)
    }

    private static func load(from url: URL) -> [String: FailureRecord] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: FailureRecord].self, from: data) else { return [:] }
        return dict
    }
}
