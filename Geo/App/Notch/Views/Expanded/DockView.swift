import SwiftUI

struct DockView: View {
    @ObservedObject var stateStore: NotchStateStore
    let metrics: NotchMetrics
    @Environment(\.appEnvironment) private var env

    @State private var blocks: [BlockEntity] = []
    @State private var tags: [Tag] = []
    @State private var searchText = ""
    @State private var selectedTagId: String?

    private var tagsById: [String: Tag] {
        Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var blockTags: [Tag] {
        let used = Set(blocks.compactMap { $0.tagId })
        return tags.filter { used.contains($0.id) }
    }

    private var filtered: [BlockEntity] {
        var result = blocks
        if let selectedTagId {
            result = result.filter { $0.tagId == selectedTagId }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(query) ||
                $0.markdown.localizedCaseInsensitiveContains(query)
            }
        }
        return Array(result.prefix(40))
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: metrics.topInset)
                .allowsHitTesting(false)

            VStack(spacing: 10) {
                DockTopBar(searchText: $searchText, count: filtered.count)
                NotchTagBar(tags: blockTags, selectedTagId: $selectedTagId)
                NotchCardRow(blocks: filtered, tagsById: tagsById)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .overlay { dropState }
            .animation(.easeInOut(duration: 0.18), value: stateStore.isDragActive)
        }
        .task {
            for await observed in env.blocksRepository.observe() { blocks = observed }
        }
        .task {
            for await observed in env.tagsRepository.observe() { tags = observed }
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
