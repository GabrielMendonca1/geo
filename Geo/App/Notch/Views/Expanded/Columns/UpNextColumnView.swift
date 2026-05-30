import SwiftUI

struct NotchCardRow: View {
    let entries: [NotchHistoryEntry]

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(entries) { entry in
                            NotchCard(entry: entry)
                                .onDrag { entry.makeDragProvider() }
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.7, anchor: .leading).combined(with: .opacity),
                                    removal: .scale(scale: 0.85).combined(with: .opacity)
                                ))
                        }
                    }
                    .padding(.vertical, 2)
                    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: entries.map(\.id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.25))
            Text("No history yet")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
