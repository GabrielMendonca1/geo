import SwiftUI

struct FABAction: View {
    let item: FABActionItem
    let index: Int
    let isExpanded: Bool
    let isFocused: Bool
    let onExecute: () -> Void

    @ViewBuilder
    var body: some View {
        if let key = item.shortcutKey {
            actionButton
                .keyboardShortcut(key, modifiers: item.shortcutModifiers)
        } else {
            actionButton
        }
    }

    private var actionButton: some View {
        Button(action: {
            performHaptic(.generic)
            onExecute()
        }) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                Text(item.label)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if let key = item.shortcutKey {
                    Text("⌘\(key.character.uppercased())")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.regularMaterial)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isFocused && isExpanded ? Color.accentColor : Color.primary.opacity(0.18),
                        lineWidth: isFocused && isExpanded ? 2 : 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .accessibilityLabel("\(item.label), \(index)")
        .accessibilityHint("Double-tap to \(item.label.lowercased())")
        .accessibilityAddTraits(.isButton)
    }

    private func performHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
