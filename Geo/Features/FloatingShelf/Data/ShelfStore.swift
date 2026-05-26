import Foundation
import Combine

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    @Published var isVisible: Bool = false

    private init() {}

    var isEmpty: Bool {
        items.isEmpty
    }

    var itemCount: Int {
        items.count
    }

    func addItem(_ item: ShelfItem) {
        items.insert(item, at: 0)
    }

    func addItems(_ newItems: [ShelfItem]) {
        items.insert(contentsOf: newItems, at: 0)
    }

    func removeItem(_ item: ShelfItem) {
        stopAccessingIfNeeded(for: item)
        items.removeAll { $0.id == item.id }
        if items.isEmpty {
            isVisible = false
        }
    }

    func removeItem(at index: Int) {
        guard index >= 0 && index < items.count else { return }
        stopAccessingIfNeeded(for: items[index])
        items.remove(at: index)
        if items.isEmpty {
            isVisible = false
        }
    }

    func removeItems(_ itemsToRemove: [ShelfItem]) {
        for item in itemsToRemove {
            stopAccessingIfNeeded(for: item)
        }
        let idsToRemove = Set(itemsToRemove.map { $0.id })
        items.removeAll { idsToRemove.contains($0.id) }
        if items.isEmpty {
            isVisible = false
        }
    }

    func clearAll() {
        for item in items {
            stopAccessingIfNeeded(for: item)
        }
        items.removeAll()
        isVisible = false
    }

    func show() {
        isVisible = true
    }

    func hide() {
        isVisible = false
    }

    private func stopAccessingIfNeeded(for item: ShelfItem) {
        guard item.didStartAccessing, let url = item.url else { return }
        url.stopAccessingSecurityScopedResource()
    }
}
