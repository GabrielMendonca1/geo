import SwiftUI

struct FABActionItem: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let badge: String?
    let shortcutKey: KeyEquivalent?
    let shortcutModifiers: EventModifiers
    let action: () -> Void

    init(icon: String, label: String, badge: String? = nil, shortcutKey: KeyEquivalent? = nil, shortcutModifiers: EventModifiers = .command, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.badge = badge
        self.shortcutKey = shortcutKey
        self.shortcutModifiers = shortcutModifiers
        self.action = action
    }
}

struct FABConfiguration {
    let primaryIcon: String
    let primaryLabel: String
    let primaryBadge: String?
    let secondaryActions: [FABActionItem]

    init(primaryIcon: String, primaryLabel: String, primaryBadge: String? = nil, secondaryActions: [FABActionItem] = []) {
        self.primaryIcon = primaryIcon
        self.primaryLabel = primaryLabel
        self.primaryBadge = primaryBadge
        self.secondaryActions = secondaryActions
    }
}
