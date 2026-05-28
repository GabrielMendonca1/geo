import Foundation

enum DestructiveOp: String, Codable, Sendable {
    case deleteBlock = "delete_block"
    case deleteTask = "delete_task"
}

struct PendingOp: Sendable {
    let transactionId: String
    let operation: DestructiveOp
    let targetId: String
    let blockVersion: Int?
    let diffPreview: String
    let callerId: String
    let createdAt: Date
}

enum PendingError: Error {
    case overflow
    case notFound
    case expired
    case staleVersion
}

final class PendingTransactionStore: @unchecked Sendable {
    static let shared = PendingTransactionStore()
    static let ttl: TimeInterval = 300
    static let maxPending: Int = 100

    private let queue = DispatchQueue(label: "geo.http.pending", qos: .utility)
    private var ops: [String: PendingOp] = [:]
    private var sweepTimer: DispatchSourceTimer?

    init() {
        startSweep()
    }

    deinit {
        sweepTimer?.cancel()
    }

    func prepare(operation: DestructiveOp, targetId: String, blockVersion: Int?, diffPreview: String, callerId: String) throws -> PendingOp {
        try queue.sync {
            evictExpiredLocked()
            if ops.count >= Self.maxPending {
                throw PendingError.overflow
            }
            let id = UUID().uuidString
            let op = PendingOp(
                transactionId: id,
                operation: operation,
                targetId: targetId,
                blockVersion: blockVersion,
                diffPreview: diffPreview,
                callerId: callerId,
                createdAt: Date()
            )
            ops[id] = op
            return op
        }
    }

    func consume(transactionId: String, expectedBlockVersion: Int?) throws -> PendingOp {
        try queue.sync {
            evictExpiredLocked()
            guard let op = ops[transactionId] else { throw PendingError.notFound }
            if Date().timeIntervalSince(op.createdAt) > Self.ttl {
                ops.removeValue(forKey: transactionId)
                throw PendingError.expired
            }
            if let expected = expectedBlockVersion, let prepared = op.blockVersion, expected != prepared {
                throw PendingError.staleVersion
            }
            ops.removeValue(forKey: transactionId)
            return op
        }
    }

    func count() -> Int {
        queue.sync { ops.count }
    }

    private func evictExpiredLocked() {
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        ops = ops.filter { $0.value.createdAt > cutoff }
    }

    private func startSweep() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            self?.evictExpiredLocked()
        }
        t.resume()
        sweepTimer = t
    }
}
