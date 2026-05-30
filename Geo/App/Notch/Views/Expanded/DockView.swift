import SwiftUI

struct DockView: View {
    @ObservedObject var stateStore: NotchStateStore
    let metrics: NotchMetrics
    @ObservedObject private var captures = LogStore.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var searchText = ""
    @State private var selectedTab = "History"

    private var entries: [NotchHistoryEntry] {
        NotchHistoryEntry.feed(captures: captures.captures, shelf: shelf.items, search: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: metrics.topInset)
                .allowsHitTesting(false)

            VStack(spacing: 10) {
                DockTopBar(searchText: $searchText, count: entries.count)
                NotchTabBar(selected: $selectedTab, historyCount: entries.count)
                NotchCardRow(entries: entries)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .overlay { dropState }
            .animation(.easeInOut(duration: 0.18), value: stateStore.isDragActive)
        }
    }

    @ViewBuilder
    private var dropState: some View {
        if stateStore.isDragActive {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Drop to shelf")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .allowsHitTesting(false)
        }
    }
}
