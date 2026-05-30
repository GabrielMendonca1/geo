import SwiftUI

struct NotchCardRow: View {
    let blocks: [BlockEntity]
    let tagsById: [String: Tag]

    var body: some View {
        Group {
            if blocks.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(blocks) { block in
                            NotchCard(block: block, tag: block.tagId.flatMap { tagsById[$0] })
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.7, anchor: .leading).combined(with: .opacity),
                                    removal: .scale(scale: 0.85).combined(with: .opacity)
                                ))
                        }
                    }
                    .padding(.vertical, 2)
                    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: blocks.map(\.id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.25))
            Text("No notes")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
