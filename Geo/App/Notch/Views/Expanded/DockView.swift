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

            VStack(spacing: 12) {
                DockTopBar(searchText: $searchText, count: entries.count)
                NotchTabBar(selected: $selectedTab, historyCount: entries.count)
                NotchCardRow(entries: entries)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }
}
