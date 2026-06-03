import SwiftUI

struct DockView: View {
    @ObservedObject var stateStore: NotchStateStore
    let metrics: NotchMetrics
    @ObservedObject private var captureStore = LogStore.shared
    @Environment(\.appEnvironment) private var env

    @State private var blocks: [BlockEntity] = []
    @State private var tags: [Tag] = []
    @State private var searchText = ""
    @State private var filter: NotchFilter = .all

    @State private var feedItems: [NotchFeedItem] = []
    @State private var tagsById: [String: Tag] = [:]
    @State private var blockTags: [Tag] = []

    private func rebuild() {
        var tagLookup: [String: Tag] = [:]
        for tag in tags {
            tagLookup[tag.id] = tag
            tagLookup[TagStore.canonicalName(tag.name)] = tag
        }
        tagsById = tagLookup
        let used = Set(blocks.compactMap { $0.tagKey(using: tags) })
        blockTags = tags.filter { used.contains(TagStore.canonicalName($0.name)) }

        var items: [NotchFeedItem]
        switch filter {
        case .all:
            items = captureStore.captures.map { .capture($0) } + blocks.map { .block($0) }
        case .images:
            items = captureStore.captures.map { .capture($0) }
        case .blocks:
            items = blocks.map { .block($0) }
        case .tag(let key):
            items = blocks.filter { $0.tagKey(using: tags) == key }.map { .block($0) }
        }
        items.sort { $0.date > $1.date }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items = items.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
        }
        feedItems = Array(items.prefix(50))
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: metrics.topInset)
                .allowsHitTesting(false)

            VStack(spacing: 10) {
                DockTopBar(stateStore: stateStore, searchText: $searchText, count: feedItems.count)
                NotchFilterBar(tags: blockTags, filter: $filter)
                NotchCardRow(items: feedItems, tagsById: tagsById)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .overlay { dropState }
            .animation(.easeInOut(duration: 0.18), value: stateStore.isDragActive)
        }
        .task {
            for await observed in env.blocksRepository.observe() { blocks = observed; rebuild() }
        }
        .task {
            for await observed in env.tagsRepository.observe() { tags = observed; rebuild() }
        }
        .onReceive(captureStore.$captures) { _ in rebuild() }
        .onChange(of: searchText) { rebuild() }
        .onChange(of: filter) { rebuild() }
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
