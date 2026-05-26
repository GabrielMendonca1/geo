import Foundation
import Combine

protocol ShelfStoreAccess: Sendable {
    func observeItems() -> AsyncStream<[ShelfItem]>
    func addItem(_ item: ShelfItem) async
    func removeItem(id: UUID) async -> Bool
    func clearAll() async
    func setVisible(_ visible: Bool) async
}

private final class ShelfObservationBox: @unchecked Sendable {
    var cancellable: AnyCancellable?
}

final class LiveShelfStoreAccess: ShelfStoreAccess, @unchecked Sendable {
    private let shelfStore: ShelfStore

    init(shelfStore: ShelfStore) {
        self.shelfStore = shelfStore
    }

    func observeItems() -> AsyncStream<[ShelfItem]> {
        AsyncStream { continuation in
            let box = ShelfObservationBox()
            let setupTask = Task { @MainActor [shelfStore] in
                continuation.yield(shelfStore.items)
                box.cancellable = shelfStore.$items
                    .dropFirst()
                    .sink { items in
                        continuation.yield(items)
                    }
            }

            continuation.onTermination = { @Sendable _ in
                setupTask.cancel()
                Task { @MainActor in
                    box.cancellable?.cancel()
                    box.cancellable = nil
                }
            }
        }
    }

    func addItem(_ item: ShelfItem) async {
        await MainActor.run {
            shelfStore.addItem(item)
        }
    }

    func removeItem(id: UUID) async -> Bool {
        await MainActor.run {
            guard let item = shelfStore.items.first(where: { $0.id == id }) else {
                return false
            }
            shelfStore.removeItem(item)
            return true
        }
    }

    func clearAll() async {
        await MainActor.run {
            shelfStore.clearAll()
        }
    }

    func setVisible(_ visible: Bool) async {
        await MainActor.run {
            if visible {
                shelfStore.show()
            } else {
                shelfStore.hide()
            }
        }
    }
}

struct ShelfStoreRepositoryAdapter: ShelfRepository, @unchecked Sendable {
    private let storeAccess: any ShelfStoreAccess

    init() {
        self.storeAccess = LiveShelfStoreAccess(
            shelfStore: MainActor.assumeIsolated { .shared }
        )
    }

    init(shelfStore: ShelfStore) {
        self.storeAccess = LiveShelfStoreAccess(shelfStore: shelfStore)
    }

    init(storeAccess: any ShelfStoreAccess) {
        self.storeAccess = storeAccess
    }

    func observe() -> AsyncStream<[ShelfItem]> {
        storeAccess.observeItems()
    }

    func add(_ item: ShelfItem) async throws {
        guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }
        await storeAccess.addItem(item)
    }

    func remove(id: UUID) async throws {
        let deleted = await storeAccess.removeItem(id: id)
        guard deleted else {
            throw RepositoryError.notFound
        }
    }

    func clear() async throws {
        await storeAccess.clearAll()
    }

    func setVisible(_ visible: Bool) async throws {
        await storeAccess.setVisible(visible)
    }
}
