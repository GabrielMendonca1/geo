import Foundation

extension Notification.Name {
    static let geoPendingAnchorChanged = Notification.Name("geoPendingAnchorChanged")
}

@MainActor
final class PendingAnchorStore: ObservableObject {
    static let shared = PendingAnchorStore()

    @Published private(set) var pending: [String: [String]] = [:]

    func enqueue(blockId: String, anchor: String) {
        pending[blockId, default: []].append(anchor)
        NotificationCenter.default.post(name: .geoPendingAnchorChanged, object: blockId)
    }

    func consume(blockId: String) -> String? {
        guard var queue = pending[blockId], !queue.isEmpty else { return nil }
        let anchor = queue.removeFirst()
        if queue.isEmpty {
            pending.removeValue(forKey: blockId)
        } else {
            pending[blockId] = queue
        }
        return anchor
    }
}
