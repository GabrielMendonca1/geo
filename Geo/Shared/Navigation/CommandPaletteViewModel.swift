import Foundation

@MainActor
@Observable
final class CommandPaletteViewModel {
    var isPresented = false
    var query = ""
    var selectedIndex = 0

    private(set) var recentItemIds: [String] = []
    private let recentItemsKey = "commandPalette.recentItemIds"
    private let maxRecents = 5

    init() {
        recentItemIds = UserDefaults.standard.stringArray(forKey: recentItemsKey) ?? []
    }

    func toggle() {
        if isPresented {
            dismiss()
        } else {
            query = ""
            selectedIndex = 0
            isPresented = true
        }
    }

    func dismiss() {
        isPresented = false
        query = ""
        selectedIndex = 0
    }

    func moveUp() {
        if selectedIndex > 0 {
            selectedIndex -= 1
        }
    }

    func moveDown(itemCount: Int) {
        if selectedIndex < itemCount - 1 {
            selectedIndex += 1
        }
    }

    func recordRecent(_ id: String) {
        recentItemIds.removeAll { $0 == id }
        recentItemIds.insert(id, at: 0)
        if recentItemIds.count > maxRecents {
            recentItemIds = Array(recentItemIds.prefix(maxRecents))
        }
        UserDefaults.standard.set(recentItemIds, forKey: recentItemsKey)
    }
}
