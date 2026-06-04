import SwiftUI

struct NotchCardRow: View {
    let items: [NotchFeedItem]
    let tagsById: [String: Tag]

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(items) { item in
                            NotchCard(item: item, tag: tagFor(item))
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.7, anchor: .leading).combined(with: .opacity),
                                    removal: .scale(scale: 0.85).combined(with: .opacity)
                                ))
                        }
                    }
                    .padding(.vertical, 2)
                    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: items.map(\.id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tagFor(_ item: NotchFeedItem) -> Tag? {
        guard case .block(let block) = item else { return nil }
        guard let name = block.metadata.tagName else { return nil }
        return tagsById[TagStore.canonicalName(name)]
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.25))
            Text("Nothing here yet")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
