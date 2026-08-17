import AppKit

enum MenuSectionID: Int, CaseIterable {
    case status
    case dictation
    case meeting
    case insomnia
    case capture
    case personalTasks
    case projects
    case app
}

final class MenuController {
    private let menu: NSMenu
    private var sections: [MenuSectionID: [NSMenuItem]] = [:]

    init(menu: NSMenu) {
        self.menu = menu
    }

    func set(_ id: MenuSectionID, items: [NSMenuItem]) {
        sections[id] = items
        rebuild()
    }

    func items(in id: MenuSectionID) -> [NSMenuItem] {
        sections[id] ?? []
    }

    private func rebuild() {
        menu.removeAllItems()
        var first = true
        for id in MenuSectionID.allCases {
            guard let items = sections[id], !items.isEmpty else { continue }
            if !first {
                menu.addItem(.separator())
            }
            for item in items {
                menu.addItem(item)
            }
            first = false
        }
    }
}
