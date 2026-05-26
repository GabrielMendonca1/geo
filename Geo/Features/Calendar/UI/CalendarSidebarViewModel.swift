import SwiftUI
import Combine

enum CalendarFilterType: String, CaseIterable, Hashable {
    case tasks
    case blocks
    case holidays

    var label: String {
        switch self {
        case .tasks: return "Tasks"
        case .blocks: return "Blocks"
        case .holidays: return "Holidays"
        }
    }

    var icon: String {
        switch self {
        case .tasks: return "clock"
        case .blocks: return "doc.text"
        case .holidays: return "star"
        }
    }
}

struct CalendarFilter: Equatable {
    var hiddenTypes: Set<CalendarFilterType> = []
    var hiddenTagIds: Set<String> = []
    var showUntagged: Bool = true

    var isActive: Bool {
        !hiddenTypes.isEmpty || !hiddenTagIds.isEmpty || !showUntagged
    }
}

@MainActor
final class CalendarSidebarViewModel: ObservableObject {
    @Published var isOpen: Bool = false
    @Published var selectedEvent: CalendarEvent?
    @Published var filter: CalendarFilter

    private static let hiddenTypesKey = "CalendarSidebar.hiddenTypes"
    private static let hiddenTagIdsKey = "CalendarSidebar.hiddenTagIds"
    private static let showUntaggedKey = "CalendarSidebar.showUntagged"

    init() {
        let savedTypes = UserDefaults.standard.stringArray(forKey: Self.hiddenTypesKey) ?? []
        let savedTags = UserDefaults.standard.stringArray(forKey: Self.hiddenTagIdsKey) ?? []
        let showUntagged = UserDefaults.standard.object(forKey: Self.showUntaggedKey) as? Bool ?? true

        self.filter = CalendarFilter(
            hiddenTypes: Set(savedTypes.compactMap { CalendarFilterType(rawValue: $0) }),
            hiddenTagIds: Set(savedTags),
            showUntagged: showUntagged
        )
    }

    func toggleType(_ type: CalendarFilterType) {
        if filter.hiddenTypes.contains(type) {
            filter.hiddenTypes.remove(type)
        } else {
            filter.hiddenTypes.insert(type)
        }
        persist()
    }

    func toggleTag(_ tagId: String) {
        if filter.hiddenTagIds.contains(tagId) {
            filter.hiddenTagIds.remove(tagId)
        } else {
            filter.hiddenTagIds.insert(tagId)
        }
        persist()
    }

    func toggleUntagged() {
        filter.showUntagged.toggle()
        persist()
    }

    func clearSelection() {
        selectedEvent = nil
    }

    private func persist() {
        UserDefaults.standard.set(filter.hiddenTypes.map(\.rawValue), forKey: Self.hiddenTypesKey)
        UserDefaults.standard.set(Array(filter.hiddenTagIds), forKey: Self.hiddenTagIdsKey)
        UserDefaults.standard.set(filter.showUntagged, forKey: Self.showUntaggedKey)
    }
}
