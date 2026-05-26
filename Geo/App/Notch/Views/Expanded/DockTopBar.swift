import SwiftUI

struct DockTopBar: View {
    @ObservedObject var stateStore: NotchStateStore

    var body: some View {
        HStack(spacing: 6) {
            Spacer()

            Button(action: { stateStore.togglePin() }) {
                Image(systemName: stateStore.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(stateStore.isPinned ? Palette.accent : Palette.tertiaryForeground)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(stateStore.isPinned ? "Unpin dock" : "Pin dock")
            .help(stateStore.isPinned ? "Unpin dock" : "Pin dock")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
