import Foundation

@MainActor
final class WorkerInbox: ObservableObject {
    struct Entry: Identifiable, Sendable {
        let id: UUID
        let workerName: String
        let kind: Kind
        let title: String
        let detail: String?
        let timestamp: Date

        enum Kind: String, Sendable {
            case createdBlock
            case createdTask
            case completedTask
            case dispatchProgress
            case dispatchComplete
            case dispatchError
            case generic
        }

        init(
            id: UUID = UUID(),
            workerName: String,
            kind: Kind,
            title: String,
            detail: String? = nil,
            timestamp: Date = Date()
        ) {
            self.id = id
            self.workerName = workerName
            self.kind = kind
            self.title = title
            self.detail = detail
            self.timestamp = timestamp
        }
    }

    @Published private(set) var entries: [Entry] = []
    private let maxEntries: Int

    init(maxEntries: Int = 50) {
        self.maxEntries = maxEntries
    }

    func record(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func recent(limit: Int = 5) -> [Entry] {
        Array(entries.prefix(limit))
    }
}
