import SwiftUI
import AppKit

struct DockView: View {
    @ObservedObject var stateStore: NotchStateStore
    let metrics: NotchMetrics
    @ObservedObject private var captureStore = LogStore.shared
    @ObservedObject private var shelfStore = ShelfStore.shared
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
                if !shelfStore.items.isEmpty {
                    NotchShelfRow(store: shelfStore)
                }
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

struct NotchShelfRow: View {
    @ObservedObject var store: ShelfStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.items) { item in
                    NotchShelfChip(item: item) { store.removeItem(item) }
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .padding(.vertical, 2)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: store.items.map(\.id))
        }
        .frame(height: 44)
    }
}

private struct NotchShelfChip: View {
    let item: ShelfItem
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 130, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white.opacity(0.9), .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
        }
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .onDrag {
            if let url = item.url { return NSItemProvider(object: url as NSURL) }
            if let image = item.image { return NSItemProvider(object: image) }
            return NSItemProvider()
        }
        .onTapGesture(count: 2) {
            if let url = item.url { NSWorkspace.shared.open(url) }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = item.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: item.type.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 30, height: 30)
        }
    }
}
