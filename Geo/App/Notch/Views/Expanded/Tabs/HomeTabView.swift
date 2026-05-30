import SwiftUI

struct NotchTabBar: View {
    @Binding var selected: String
    let historyCount: Int

    private let tabs = ["History", "Prompts", "Colors", "Assets", "Inspirations"]
    private let placeholderCount = 24

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs, id: \.self) { tab in
                NotchChip(
                    title: tab,
                    count: tab == "History" ? historyCount : placeholderCount,
                    isActive: tab == selected,
                    action: { if tab == "History" { selected = tab } }
                )
            }
            NotchChip(systemImage: "plus")
            Spacer(minLength: 0)
        }
    }
}
