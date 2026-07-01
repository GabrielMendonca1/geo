import SwiftUI
import AppKit
import Combine

struct NodesPane: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @EnvironmentObject private var blocksViewModel: BlocksViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.tabRouter) private var tabRouter
    @Environment(\.navigationStore) private var navigationStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var graphStore = GraphStore.shared
    @StateObject private var listState = BlocksListState()
    @StateObject private var docTabs = DocTabsModel()
    @State private var pendingFocus: FocusRequest?
    @AppStorage("nodesPane.sidebarWidth") private var sidebarWidth: Double = 280
    @AppStorage("nodesPane.graphWidth") private var graphWidth: Double = 360
    @AppStorage("nodesPane.leftHidden") private var leftHidden: Bool = false
    @FocusState private var graphSearchFocused: Bool

    private var sidebarBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(sidebarWidth) }, set: { sidebarWidth = Double($0) })
    }
    private var graphBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(graphWidth) }, set: { graphWidth = Double($0) })
    }

    var body: some View {
        Pane {
            splitContent
                .background(GraphView.canvasColor(for: colorScheme).ignoresSafeArea())
                .overlay {
                    graphSearchOverlay
                        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: navigationStore.graphSearchPresented)
                }
        }
        .task {
            blocksViewModel.bindIfNeeded(
                blocksRepository: appEnvironment.blocksRepository,
                tagsRepository: appEnvironment.tagsRepository
            )
            graphStore.startObserving(blocksViewModel)
        }
        .onChange(of: blocksViewModel.blocks.map(\.id)) { _, _ in
            docTabs.resync { id in
                blocksViewModel.block(withID: id).map { OpenDocRef(id: $0.id, title: $0.displayTitle, url: $0.url) }
            }
        }
        .onDisappear { docTabs.flushAll() }
    }

    private func toggleSidebar() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            leftHidden.toggle()
        }
    }

    // Toolbar lives in the sidebar header (not a full-width band) so the editor tabs and graph rise to
    // the top of the pane — no dead space above them.
    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            BlocksControlBar(
                listState: listState,
                sidebarHidden: false,
                onToggleSidebar: { toggleSidebar() },
                onOpenBlock: { openBlock($0) }
            )
            BlocksPane(externalFocus: pendingFocus, listState: listState, onOpen: { openBlock($0) })
        }
    }

    // The toggle lives in the sidebar; this floating chip is the only way back once it's hidden.
    private var showSidebarButton: some View {
        Button { toggleSidebar() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .padding(8)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Show list")
        .accessibilityLabel("Show list")
    }

    // MARK: - Open routing

    // Open a block we already hold (no store re-lookup → no race right after createBlock).
    private func openBlock(_ block: BlockEntity) {
        // One editor per block: if it's already in a detached window, focus that instead of a tab.
        if FileOpenCoordinator.shared.focusBlockWindow(block.id) { return }
        docTabs.open(OpenDocRef(id: block.id, title: block.displayTitle, url: block.url))
    }

    private func openBlockId(_ id: String) {
        if FileOpenCoordinator.shared.focusBlockWindow(id) { return }
        guard let block = blocksViewModel.block(withID: id) else { return }
        openBlock(block)
    }

    private var editorTabs: some View {
        DocTabsView(
            model: docTabs,
            onWikiLink: { target in
                if let block = blocksViewModel.blocks.first(where: {
                    $0.displayTitle.localizedCaseInsensitiveCompare(target) == .orderedSame
                }) {
                    openBlock(block)
                }
            },
            onNew: {
                Task {
                    if let block = await blocksViewModel.createBlock(title: "", markdown: "") {
                        openBlock(block)
                    }
                }
            },
            onPopOut: { ref in
                openWindow(value: ref.id)       // detached editable window (existing BlockEditorView)
                docTabs.close(ref.id)           // one editor per block — hand it off to the window
            },
            backlinks: { ref in (await IndexCoordinator.shared.findBacklinks(for: ref.title)).count },
            emptyState: AnyView(editorEmpty),
            statusAccessory: { ref in AnyView(NodesDocControls(blockId: ref.id)) },
            contentMaxWidth: { ref in
                (blocksViewModel.block(withID: ref.id)?.metadata.isFullWidth ?? false) ? .infinity : 720
            }
        )
    }

    private var editorEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 40, weight: .thin))
                .foregroundStyle(Palette.tertiaryForeground.opacity(0.5))
            Text("Select a note").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground)
            Text("Click a note in the sidebar or graph to open it here. Pop it out to a window from the tab.")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiaryForeground)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var graphColumn: some View {
        GraphView(
            graph: graphStore.graph,
            seedPositions: graphStore.cachedPositions,
            wasSettled: graphStore.simulationSettled,
            externalChangeSignal: graphStore.externalChangeSignal,
            onLayoutChange: { positions, settled in
                graphStore.updateLayoutCache(positions: positions, settled: settled)
            },
            isActive: { [tabRouter] in tabRouter.selectedTab == .nodes },
            persistsSettings: false,        // re-fit to the (narrower) column each time, don't restore old pan/zoom
            initialFitScale: 0.42,          // zoomed further out so the whole graph fills the column
            maxInitialZoom: 0.6,
            minZoom: 0.08,
            searchQuery: navigationStore.searchTexts[.nodes] ?? ""
        ) { id in
            if let blockId = graphStore.idLookup[id] {
                pendingFocus = FocusRequest(blockId: blockId, token: UUID())
                openBlockId(blockId)
            }
        }
        .clipped()
    }

    @ViewBuilder private var splitContent: some View {
        let hasTabs = !docTabs.openRefs.isEmpty
        if leftHidden {
            ZStack(alignment: .topLeading) {
                if hasTabs {
                    TwoColumnSplit(rightWidth: graphBinding, rightRange: 240...620) {
                        editorTabs
                    } right: {
                        graphColumn
                    }
                } else {
                    graphColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                showSidebarButton.padding(.top, 6).padding(.leading, 6)
            }
        } else {
            // No note open → editor column collapses and the graph fills the space beside the sidebar.
            ThreeColumnSplit(
                leftWidth: sidebarBinding,
                rightWidth: graphBinding,
                leftRange: 220...460,
                rightRange: 240...620,
                showCenter: hasTabs
            ) {
                sidebarColumn
            } center: {
                editorTabs
            } right: {
                graphColumn
            }
        }
    }

    // MARK: - Graph search overlay

    private var graphSearchQuery: Binding<String> {
        Binding(
            get: { navigationStore.searchTexts[.nodes] ?? "" },
            set: { navigationStore.searchTexts[.nodes] = $0 }
        )
    }

    private func closeGraphSearch() {
        graphSearchFocused = false
        navigationStore.searchTexts[.nodes] = ""
        navigationStore.graphSearchPresented = false
    }

    @ViewBuilder
    private var graphSearchOverlay: some View {
        if navigationStore.graphSearchPresented && tabRouter.selectedTab == .nodes {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search nodes", text: graphSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .frame(width: 360)
                    .focused($graphSearchFocused)
                    .onSubmit { openFirstMatch() }
                    .onKeyPress(.escape) {
                        closeGraphSearch()
                        return .handled
                    }
                if !graphSearchQuery.wrappedValue.isEmpty {
                    Button { navigationStore.searchTexts[.nodes] = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 10)
            .padding(.top, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            .onAppear { graphSearchFocused = true }
        }
    }

    private func openFirstMatch() {
        let fold = { (s: String) in s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
        let needle = fold(navigationStore.searchTexts[.nodes] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let matches = blocksViewModel.blocks.filter { fold($0.displayTitle).contains(needle) }
        let best = matches.first { fold($0.displayTitle) == needle }
            ?? matches.first { fold($0.displayTitle).hasPrefix(needle) }
            ?? matches.first
        if let best {
            openBlock(best)
            closeGraphSearch()
        }
    }
}

// The detached editor's metadata chips (type · layer · status), embedded in the tab's status bar.
// Reads the live block by id and writes through BlocksViewModel; icon-only to fit the narrow column.
private struct NodesDocControls: View {
    let blockId: String
    @EnvironmentObject private var viewModel: BlocksViewModel

    var body: some View {
        if let block = viewModel.block(withID: blockId) {
            HStack(spacing: 8) {
                typeMenu(block)
                layerMenu(block)
                statusMenu(block)
                tagMenu(block)
                fullWidthToggle(block)
            }
        }
    }

    private func chip(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.tertiaryForeground)
            .frame(width: 24, height: 18)
            .contentShape(Rectangle())
    }

    private func typeMenu(_ block: BlockEntity) -> some View {
        Menu {
            ForEach(BlockType.allCases, id: \.self) { type in
                Button {
                    Task { _ = await viewModel.setType(type, for: blockId) }
                } label: {
                    Label(type.displayName, systemImage: block.metadata.type == type ? "checkmark" : type.icon)
                }
            }
        } label: {
            chip(block.metadata.type.icon)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Tipo: \(block.metadata.type.displayName)")
    }

    private func layerMenu(_ block: BlockEntity) -> some View {
        Menu {
            ForEach(BlockLayer.allCases, id: \.self) { layer in
                Button {
                    Task { _ = await viewModel.setLayer(layer, for: blockId) }
                } label: {
                    Label(layer.displayName, systemImage: block.metadata.layer == layer ? "checkmark" : layer.icon)
                }
            }
        } label: {
            chip(block.metadata.layer.icon)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Camada: \(block.metadata.layer.displayName)")
    }

    private func statusMenu(_ block: BlockEntity) -> some View {
        let current = block.metadata.status.flatMap(BlockStatus.init(rawValue:))
        return Menu {
            ForEach(BlockStatus.allCases, id: \.self) { status in
                Button {
                    Task { _ = await viewModel.setStatus(status, for: blockId) }
                } label: {
                    Label(status.displayName, systemImage: current == status ? "checkmark" : status.icon)
                }
            }
        } label: {
            chip(current?.icon ?? "circle.dashed")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Status: \(current?.displayName ?? "—")")
    }

    private func tagMenu(_ block: BlockEntity) -> some View {
        let currentName = block.metadata.tagName
        let currentTag = currentName.flatMap { name in
            viewModel.tags.first { TagStore.canonicalName($0.name) == TagStore.canonicalName(name) }
        }
        return Menu {
            Button {
                Task { _ = await viewModel.setTag(nil, for: blockId) }
            } label: {
                Label("Sem tag", systemImage: currentName == nil ? "checkmark" : "tag.slash")
            }
            ForEach(viewModel.tags, id: \.id) { tag in
                Button {
                    Task { _ = await viewModel.setTag(tag.id, for: blockId) }
                } label: {
                    Label(tag.name, systemImage: currentTag?.id == tag.id ? "checkmark" : "tag.fill")
                }
            }
        } label: {
            Image(systemName: "tag.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(currentTag?.color.swiftUIColor ?? Palette.tertiaryForeground)
                .frame(width: 24, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(currentName.map { "Tag: \($0)" } ?? "Tag")
    }

    private func fullWidthToggle(_ block: BlockEntity) -> some View {
        let on = block.metadata.isFullWidth
        return Button {
            Task { _ = await viewModel.setFullWidth(!on, for: blockId) }
        } label: {
            chip(on ? "arrow.left.and.right.square.fill" : "arrow.left.and.right.square")
        }
        .buttonStyle(.plain)
        .help(on ? "Largura total: ligada" : "Largura total: desligada")
    }
}
