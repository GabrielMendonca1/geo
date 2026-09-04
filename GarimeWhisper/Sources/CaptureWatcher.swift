import Foundation

struct CaptureSnapshot: Equatable {
    var exists = false
    var heartbeat: Date?
    var strandedCount = 0
    var processedStamp: Date?
}

enum CaptureCondition: Equatable {
    case absent
    case healthy
    case stranded(Int)
    case silent(TimeInterval)
}

enum CaptureProbe {
    static func read(root: String) -> CaptureSnapshot {
        var snapshot = CaptureSnapshot()
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: root + "/status", isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return snapshot }
        snapshot.exists = true
        snapshot.heartbeat = mtime(root + "/status/capture.heartbeat")
        snapshot.processedStamp = mtime(root + "/registry/processed.json")
        if let raw = try? String(contentsOfFile: root + "/status/stranded", encoding: .utf8) {
            snapshot.strandedCount = raw
                .split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .count
        }
        return snapshot
    }

    static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func condition(_ snapshot: CaptureSnapshot, now: Date) -> CaptureCondition {
        guard snapshot.exists else { return .absent }
        if snapshot.strandedCount > 0 { return .stranded(snapshot.strandedCount) }
        guard let heartbeat = snapshot.heartbeat else { return .silent(.infinity) }
        let age = now.timeIntervalSince(heartbeat)
        if age > Config.captureHeartbeatMaxAge { return .silent(age) }
        return .healthy
    }

    static func line(for condition: CaptureCondition) -> String? {
        switch condition {
        case .absent, .healthy:
            return nil
        case .stranded(let count):
            return count == 1 ? "Prints: 1 preso" : "Prints: \(count) presos"
        case .silent(let age):
            guard age.isFinite else { return "Prints: daemon sem heartbeat" }
            return "Prints: daemon parado há \(Int(age / 60)) min"
        }
    }
}

final class CaptureWatcher {
    private var timer: Timer?
    private var last = CaptureSnapshot()
    private var primed = false
    let root: String

    var onProcessed: (() -> Void)?
    var onCondition: ((CaptureCondition) -> Void)?

    init(root: String = Config.captureRoot) {
        self.root = root
    }

    func start() {
        poll()
        let ticker = Timer(timeInterval: Config.capturePollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll(now: Date = Date()) {
        let snapshot = CaptureProbe.read(root: root)
        if primed, let stamp = snapshot.processedStamp, stamp != last.processedStamp {
            onProcessed?()
        }
        onCondition?(CaptureProbe.condition(snapshot, now: now))
        last = snapshot
        primed = true
    }
}
