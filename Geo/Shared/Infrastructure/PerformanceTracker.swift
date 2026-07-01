import Foundation
import os.signpost

final class PerformanceTracker: @unchecked Sendable {
    static let shared = PerformanceTracker()

    private let log = OSLog(subsystem: "com.geo.performance", category: "Instrumentation")
    private let pointsOfInterest = OSLog(subsystem: "com.geo.performance", category: .pointsOfInterest)

    private let lock = NSLock()
    private var _startupBegin: CFAbsoluteTime = 0
    private var _startupDuration: Double?
    private var _tabSwitchLatencies: [(from: String, to: String, ms: Double)] = []
    private var _storeOperations: [StoreOperation] = []
    private var _cacheHits: Int = 0
    private var _cacheMisses: Int = 0
    private var _renderCounts: [String: Int] = [:]

    struct StoreOperation {
        let store: String
        let operation: String
        let durationMs: Double
        let timestamp: Date
    }

    private let maxRetainedOperations = 200
    private let maxRetainedLatencies = 50

    var startupDuration: Double? {
        lock.withLock { _startupDuration }
    }

    var tabSwitchLatencies: [(from: String, to: String, ms: Double)] {
        lock.withLock { _tabSwitchLatencies }
    }

    var averageTabSwitchMs: Double {
        lock.withLock {
            guard !_tabSwitchLatencies.isEmpty else { return 0 }
            return _tabSwitchLatencies.map(\.ms).reduce(0, +) / Double(_tabSwitchLatencies.count)
        }
    }

    var storeOperations: [StoreOperation] {
        lock.withLock { _storeOperations }
    }

    var cacheHitRate: Double {
        lock.withLock {
            let total = _cacheHits + _cacheMisses
            guard total > 0 else { return 0 }
            return Double(_cacheHits) / Double(total) * 100
        }
    }

    var cacheHits: Int {
        lock.withLock { _cacheHits }
    }

    var cacheMisses: Int {
        lock.withLock { _cacheMisses }
    }

    var renderCounts: [String: Int] {
        lock.withLock { _renderCounts }
    }

    func markStartupBegin() {
        lock.withLock {
            _startupBegin = CFAbsoluteTimeGetCurrent()
            os_signpost(.begin, log: pointsOfInterest, name: "AppStartup")
        }
    }

    func markStartupEnd() {
        let end = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            let duration = (end - _startupBegin) * 1000
            _startupDuration = duration
            os_signpost(.end, log: pointsOfInterest, name: "AppStartup")
        }
    }

    func beginStoreOperation(_ store: String, operation: String) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "StoreOperation", signpostID: id, "%{public}s.%{public}s", store, operation)
        return id
    }

    func endStoreOperation(_ store: String, operation: String, signpostID: OSSignpostID, startTime: CFAbsoluteTime) {
        os_signpost(.end, log: log, name: "StoreOperation", signpostID: signpostID, "%{public}s.%{public}s", store, operation)
        let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        lock.withLock {
            _storeOperations.append(StoreOperation(store: store, operation: operation, durationMs: durationMs, timestamp: Date()))
            if _storeOperations.count > maxRetainedOperations {
                _storeOperations.removeFirst(_storeOperations.count - maxRetainedOperations)
            }
        }
    }

    func trackTabSwitch(from: String, to: String, durationMs: Double) {
        os_signpost(.event, log: pointsOfInterest, name: "TabSwitch", "%{public}s -> %{public}s (%.2f ms)", from, to, durationMs)
        lock.withLock {
            _tabSwitchLatencies.append((from: from, to: to, ms: durationMs))
            if _tabSwitchLatencies.count > maxRetainedLatencies {
                _tabSwitchLatencies.removeFirst(_tabSwitchLatencies.count - maxRetainedLatencies)
            }
        }
    }

    func recordCacheHit() {
        os_signpost(.event, log: log, name: "EventCacheHit")
        lock.withLock {
            _cacheHits += 1
        }
    }

    func recordCacheMiss() {
        os_signpost(.event, log: log, name: "EventCacheMiss")
        lock.withLock {
            _cacheMisses += 1
        }
    }

    func recordRender(_ viewName: String) {
        lock.withLock {
            _renderCounts[viewName, default: 0] += 1
        }
    }

    func reset() {
        lock.withLock {
            _startupDuration = nil
            _tabSwitchLatencies.removeAll()
            _storeOperations.removeAll()
            _cacheHits = 0
            _cacheMisses = 0
            _renderCounts.removeAll()
        }
    }
}

func signpostedStoreOperation<T>(_ store: String, _ operation: String, body: () throws -> T) rethrows -> T {
    let tracker = PerformanceTracker.shared
    let start = CFAbsoluteTimeGetCurrent()
    let spID = tracker.beginStoreOperation(store, operation: operation)
    let result = try body()
    tracker.endStoreOperation(store, operation: operation, signpostID: spID, startTime: start)
    return result
}

func signpostedStoreOperation<T>(_ store: String, _ operation: String, body: () async throws -> T) async rethrows -> T {
    let tracker = PerformanceTracker.shared
    let start = CFAbsoluteTimeGetCurrent()
    let spID = tracker.beginStoreOperation(store, operation: operation)
    let result = try await body()
    tracker.endStoreOperation(store, operation: operation, signpostID: spID, startTime: start)
    return result
}
