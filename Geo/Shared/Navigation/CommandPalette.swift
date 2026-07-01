import SwiftUI

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String
    let kind: ItemKind
    let shortcut: String?
    let action: () -> Void

    enum ItemKind: String {
        case block
        case command
        case tag
        case navigation
    }
}

struct CommandPalette: View {
    @Bindable var viewModel: CommandPaletteViewModel
    let items: [CommandPaletteItem]

    @FocusState private var isSearchFocused: Bool

    private var filteredItems: [CommandPaletteItem] {
        let q = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return limitedItems(from: items)
        }
        let matched = items.filter {
            $0.title.lowercased().contains(q) ||
            ($0.subtitle?.lowercased().contains(q) ?? false)
        }
        return limitedItems(from: matched)
    }

    private func limitedItems(from source: [CommandPaletteItem]) -> [CommandPaletteItem] {
        var counts: [CommandPaletteItem.ItemKind: Int] = [:]
        var result: [CommandPaletteItem] = []
        for item in source {
            guard result.count < 20 else { break }
            let kindCount = counts[item.kind, default: 0]
            guard kindCount < 8 else { continue }
            counts[item.kind] = kindCount + 1
            result.append(item)
        }
        return result
    }

    private var groupedItems: [(String, [CommandPaletteItem])] {
        let items = filteredItems
        var sections: [(String, [CommandPaletteItem])] = []
        var currentKind: CommandPaletteItem.ItemKind?
        var currentItems: [CommandPaletteItem] = []

        for item in items {
            if item.kind != currentKind {
                if let kind = currentKind, !currentItems.isEmpty {
                    sections.append((sectionTitle(for: kind), currentItems))
                }
                currentKind = item.kind
                currentItems = [item]
            } else {
                currentItems.append(item)
            }
        }
        if let kind = currentKind, !currentItems.isEmpty {
            sections.append((sectionTitle(for: kind), currentItems))
        }
        return sections
    }

    private func sectionTitle(for kind: CommandPaletteItem.ItemKind) -> String {
        switch kind {
        case .block: return "Blocks"
        case .command: return "Commands"
        case .tag: return "Tags"
        case .navigation: return "Navigation"
        }
    }

    private func flatIndex(of item: CommandPaletteItem) -> Int? {
        filteredItems.firstIndex(where: { $0.id == item.id })
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.dismiss()
                }

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: paletteTopOffset)

                VStack(spacing: 0) {
                    searchField
                    Divider()
                    resultsList
                }
                .frame(width: 500)
                .frame(maxHeight: 400)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 8)

                Spacer()
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.selectedIndex = 0
        }
    }

    private var paletteTopOffset: CGFloat {
        80
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Type a command or search...", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isSearchFocused)
                .onSubmit {
                    executeSelected()
                }
                .onKeyPress(.upArrow) {
                    viewModel.moveUp()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    viewModel.moveDown(itemCount: filteredItems.count)
                    return .handled
                }
                .onKeyPress(.escape) {
                    viewModel.dismiss()
                    return .handled
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedItems, id: \.0) { sectionTitle, sectionItems in
                        sectionHeader(sectionTitle)
                        ForEach(sectionItems) { item in
                            let idx = flatIndex(of: item) ?? 0
                            itemRow(item, isSelected: idx == viewModel.selectedIndex)
                                .id(item.id)
                                .onTapGesture {
                                    viewModel.selectedIndex = idx
                                    executeItem(item)
                                }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: viewModel.selectedIndex) { _, newIndex in
                if newIndex < filteredItems.count {
                    proxy.scrollTo(filteredItems[newIndex].id, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func itemRow(_ item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 14))
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Spacer()

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func executeSelected() {
        let items = filteredItems
        guard viewModel.selectedIndex < items.count else { return }
        executeItem(items[viewModel.selectedIndex])
    }

    private func executeItem(_ item: CommandPaletteItem) {
        viewModel.recordRecent(item.id)
        viewModel.dismiss()
        item.action()
    }
}

struct CommandPaletteOverlay: View {
    @Bindable var viewModel: CommandPaletteViewModel
    @Environment(\.navigationStore) private var navigationStore
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var blocksViewModel: BlocksViewModel

    var body: some View {
        if viewModel.isPresented {
            CommandPalette(viewModel: viewModel, items: buildItems())
                .animation(.spring(response: 0.2), value: viewModel.isPresented)
        }
    }

    private func buildItems() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        let recentIds = viewModel.recentItemIds
        if !recentIds.isEmpty {
            for recentId in recentIds {
                if let block = blocksViewModel.blocks.first(where: { $0.id == recentId }) {
                    items.append(CommandPaletteItem(
                        id: "recent-\(block.id)",
                        title: block.displayTitle,
                        subtitle: "block",
                        icon: "doc.text",
                        kind: .block,
                        shortcut: nil,
                        action: { [openWindow] in openWindow(value: block.id) }
                    ))
                }
            }
        }

        items += buildBlockItems()
        items += buildCommandItems()
        items += buildNavigationItems()
        items += buildTagItems()

        return items
    }

    private func buildBlockItems() -> [CommandPaletteItem] {
        let recentIds = Set(viewModel.recentItemIds)
        return blocksViewModel.blocks
            .filter { !recentIds.contains($0.id) }
            .prefix(8)
            .map { block in
                CommandPaletteItem(
                    id: "block-\(block.id)",
                    title: block.displayTitle,
                    subtitle: "block",
                    icon: "doc.text",
                    kind: .block,
                    shortcut: nil,
                    action: { [openWindow] in openWindow(value: block.id) }
                )
            }
    }

    private func buildCommandItems() -> [CommandPaletteItem] {
        [
            CommandPaletteItem(
                id: "cmd-new-block",
                title: "New Block",
                subtitle: nil,
                icon: "plus.circle",
                kind: .command,
                shortcut: "⌘N",
                action: { [openWindow] in
                    Task { @MainActor in
                        if let newBlock = await blocksViewModel.createBlock(title: "", markdown: "") {
                            openWindow(value: newBlock.id)
                        }
                    }
                }
            ),
            CommandPaletteItem(
                id: "cmd-settings",
                title: "Show Settings",
                subtitle: nil,
                icon: "gearshape",
                kind: .command,
                shortcut: "⌘,",
                action: { [navigationStore] in
                    navigationStore.selectTab(.settings)
                }
            ),
        ]
    }

    private func buildNavigationItems() -> [CommandPaletteItem] {
        let tabs: [(AppTab, String)] = [
            (.tasks, "checklist.unchecked"),
            (.nodes, "point.3.connected.trianglepath.dotted"),
            (.nano, "rectangle.grid.2x2.fill"),
            (.settings, "gearshape"),
        ]
        return tabs.map { tab, icon in
            CommandPaletteItem(
                id: "nav-\(tab.rawValue)",
                title: "Go to \(tab.displayTitle)",
                subtitle: nil,
                icon: icon,
                kind: .navigation,
                shortcut: tab.shortcutHint.isEmpty ? nil : tab.shortcutHint,
                action: { [navigationStore] in
                    navigationStore.selectTab(tab)
                }
            )
        }
    }

    private func buildTagItems() -> [CommandPaletteItem] {
        blocksViewModel.tags.map { tag in
            CommandPaletteItem(
                id: "tag-\(tag.id)",
                title: tag.name,
                subtitle: "tag",
                icon: "tag",
                kind: .tag,
                shortcut: nil,
                action: { [navigationStore] in
                    navigationStore.selectTab(.nodes)
                }
            )
        }
    }
}
