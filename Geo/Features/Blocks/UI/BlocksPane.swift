import SwiftUI
import AppKit

struct FocusRequest: Equatable {
    let blockId: String
    let token: UUID
}

@MainActor
final class BlocksListState: ObservableObject {
    @Published var selectedBlockIds: Set<String> = []
    @Published var focusedBlockId: String?
}

struct BlocksPane: View {
    let externalFocus: FocusRequest?
    @ObservedObject var listState: BlocksListState
    // When set, a plain click opens the block here (embedded tab) instead of a detached window.
    var onOpen: ((BlockEntity) -> Void)? = nil

    init(externalFocus: FocusRequest? = nil, listState: BlocksListState, onOpen: ((BlockEntity) -> Void)? = nil) {
        self.externalFocus = externalFocus
        self.listState = listState
        self.onOpen = onOpen
    }

    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.navigationStore) private var navigationStore
    @EnvironmentObject private var viewModel: BlocksViewModel
    @Environment(\.openWindow) var openWindow
    @State private var debouncedSearchText = ""
    @State private var searchDebounceWorkItem: DispatchWorkItem?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchResults: [BlockEntity] = []
    @State private var pendingDeleteBlock: BlockEntity? = nil
    @AppStorage("blocksPane.collapsedFolders") private var collapsedFoldersRaw = ""
    @State private var knownFolders: [String] = []
    @State private var isFolderPromptPresented = false
    @State private var folderPromptTitle = "New Folder"
    @State private var folderPromptName = ""
    @State private var folderPromptAction: ((String) -> Void)? = nil

    var body: some View {
        Pane {
            blocksList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(
            "Apagar permanent note?",
            isPresented: Binding(
                get: { pendingDeleteBlock != nil },
                set: { if !$0 { pendingDeleteBlock = nil } }
            ),
            presenting: pendingDeleteBlock
        ) { block in
            Button("Apagar mesmo assim", role: .destructive) {
                let id = block.id
                pendingDeleteBlock = nil
                Task { @MainActor in
                    _ = await viewModel.deleteBlock(id: id)
                }
            }
            Button("Cancelar", role: .cancel) {
                pendingDeleteBlock = nil
            }
        } message: { _ in
            Text("Permanent notes deveriam crescer com o tempo. Considere arquivar (`status: archived`) em vez de deletar.")
        }
        .alert(folderPromptTitle, isPresented: $isFolderPromptPresented) {
            TextField("Folder name", text: $folderPromptName)
            Button("Cancel", role: .cancel) { folderPromptName = "" }
            Button("Create") {
                let trimmed = folderPromptName.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                folderPromptName = ""
                guard !trimmed.isEmpty else { return }
                folderPromptAction?(trimmed)
            }
        }
        .task {
            viewModel.bindIfNeeded(
                blocksRepository: appEnvironment.blocksRepository,
                tagsRepository: appEnvironment.tagsRepository
            )
            await refreshFolders()
        }
    }

    private var visibleBlocks: [BlockEntity] {
        viewModel.filteredBlocks(
            debouncedSearchText: debouncedSearchText,
            searchResults: searchResults,
            selectedTagFilter: nil,
            taskFilter: nil,
            statusFilter: .active,
            sortField: .lastEdited,
            sortOrder: .newest
        )
    }

    private var isSearching: Bool {
        !debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshSearchResults(for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchTask?.cancel()
            searchResults = []
            return
        }

        searchTask?.cancel()
        searchTask = Task {
            let results = await viewModel.searchBlocks(matching: trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                    searchResults = results
                }
            }
        }
    }

    private var blocksList: some View {
        ScrollView {
            let visibleBlocks = self.visibleBlocks
            if !viewModel.hasLoadedInitialSnapshot {
                loadingState
            } else if viewModel.blocks.isEmpty {
                emptyState
            } else if visibleBlocks.isEmpty {
                noResultsState
            } else {
                listContent(visibleBlocks)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !listState.selectedBlockIds.isEmpty {
                listState.selectedBlockIds.removeAll()
            }
            listState.focusedBlockId = nil
        }
        .onChange(of: navigationStore.searchTexts[.nodes]) { _, newValue in
            let value = newValue ?? ""
            searchDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                debouncedSearchText = value
            }
            searchDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        }
        .onChange(of: debouncedSearchText) { oldValue, newValue in
            refreshSearchResults(for: newValue)
        }
        .onChange(of: externalFocus) { _, newValue in
            guard let id = newValue?.blockId else { return }
            listState.focusedBlockId = id
            navigationStore.searchTexts[.nodes] = ""
            debouncedSearchText = ""
            searchResults = []
        }
        .onAppear {
            let current = navigationStore.searchTexts[.nodes] ?? ""
            debouncedSearchText = current
            refreshSearchResults(for: current)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading blocks...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var collapsedFolders: Set<String> {
        Set(collapsedFoldersRaw.split(separator: "\n").map(String.init))
    }

    private func toggleFolder(_ path: String) {
        var set = collapsedFolders
        if set.contains(path) { set.remove(path) } else { set.insert(path) }
        collapsedFoldersRaw = set.sorted().joined(separator: "\n")
    }

    private func folderOf(_ block: BlockEntity) -> String {
        block.id.split(separator: "/").map(String.init).dropLast().joined(separator: "/")
    }

    private var allFolders: [String] {
        var set = Set(knownFolders)
        for block in viewModel.blocks {
            let components = block.id.split(separator: "/").map(String.init).dropLast()
            var accumulated = ""
            for component in components {
                accumulated = accumulated.isEmpty ? component : accumulated + "/" + component
                set.insert(accumulated)
            }
        }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func refreshFolders() async {
        knownFolders = await viewModel.listFolders()
    }

    private func promptFolderName(title: String, _ completion: @escaping (String) -> Void) {
        folderPromptTitle = title
        folderPromptName = ""
        folderPromptAction = completion
        isFolderPromptPresented = true
    }

    private func moveBlock(_ block: BlockEntity, toFolder folder: String?) {
        Task { @MainActor in
            if await viewModel.moveBlock(id: block.id, toFolder: folder) {
                await refreshFolders()
            }
        }
    }

    private func dropBlock(id: String, intoFolder folder: String) {
        guard let block = viewModel.blocks.first(where: { $0.id == id }) else { return }
        guard folderOf(block) != folder else { return }
        moveBlock(block, toFolder: folder.isEmpty ? nil : folder)
    }

    private func newBlock(inFolder folder: String) {
        Task { @MainActor in
            let target = folder.isEmpty ? nil : folder
            if let block = await viewModel.createBlock(title: "", markdown: "", folder: target) {
                await refreshFolders()
                openWindow(value: block.id)
            }
        }
    }

    private func createSubfolder(parent: String, name: String) {
        let path = parent.isEmpty ? name : parent + "/" + name
        Task { @MainActor in
            if await viewModel.createFolder(path) {
                await refreshFolders()
            }
        }
    }

    private func listContent(_ visibleBlocks: [BlockEntity]) -> some View {
        Group {
            if isSearching {
                LazyVStack(spacing: 1) {
                    ForEach(visibleBlocks) { block in
                        blockRow(for: block)
                    }
                }
            } else {
                LazyVStack(spacing: 1) {
                    FolderTreeRows(
                        node: viewModel.folderTree(for: visibleBlocks, extraFolders: knownFolders),
                        depth: 0,
                        collapsed: collapsedFolders,
                        onToggle: toggleFolder,
                        blockRow: { AnyView(blockRow(for: $0)) },
                        onNewBlock: { newBlock(inFolder: $0) },
                        onNewSubfolder: { parent in
                            promptFolderName(title: "New Subfolder") { createSubfolder(parent: parent, name: $0) }
                        },
                        onDropBlock: { dropBlock(id: $0, intoFolder: $1) }
                    )
                }
            }
        }
        .padding(.horizontal, GeoStyle.Spacing.editorPadding)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }

    private func blockRow(for block: BlockEntity) -> some View {
        Button {
            handleBlockClick(block)
        } label: {
            BlockListRow(
                block: block,
                isSelected: listState.selectedBlockIds.contains(block.id)
            )
        }
        .contentShape(Rectangle())
        .accessibilityLabel(block.displayTitle.isEmpty ? "Untitled block" : block.displayTitle)
        .accessibilityHint("Double-tap to open editor")
        .plainNoFocusButton()
        .onDrag { NSItemProvider(object: block.id as NSString) }
        .contextMenu {
            Menu {
                if !folderOf(block).isEmpty {
                    Button {
                        moveBlock(block, toFolder: nil)
                    } label: {
                        Label("Root", systemImage: "house")
                    }
                }
                ForEach(allFolders.filter { $0 != folderOf(block) }, id: \.self) { folder in
                    Button {
                        moveBlock(block, toFolder: folder)
                    } label: {
                        Label(folder, systemImage: "folder")
                    }
                }
                Divider()
                Button {
                    promptFolderName(title: "Move to New Folder") { moveBlock(block, toFolder: $0) }
                } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("Move to Folder", systemImage: "folder")
            }
            Button(role: .destructive) {
                requestDelete(block)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                openWindow(value: block.id)
            } label: {
                Label("Open in New Window", systemImage: "macwindow")
            }
        }
    }

    private func requestDelete(_ block: BlockEntity) {
        if BlockLifecycleActions(viewModel: viewModel).shouldConfirmDelete(block) {
            pendingDeleteBlock = block
        } else {
            Task { @MainActor in
                _ = await viewModel.deleteBlock(id: block.id)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 52))
                .foregroundColor(.secondary.opacity(0.5))
                .accessibilityHidden(true)
            Text("No blocks created")
                .font(.title3.weight(.semibold))
                .foregroundColor(.secondary)
                .accessibilityAddTraits(.isStaticText)
            Text("Create a new page to get started.")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.8))
                .accessibilityAddTraits(.isStaticText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No search results")
                .font(.title3.weight(.semibold))
                .foregroundColor(.secondary)
            Text("Try a different keyword.")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.8))
            Button("Clear Search") {
                navigationStore.searchTexts[.nodes] = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func handleBlockClick(_ block: BlockEntity) {
        listState.focusedBlockId = block.id
        if NSEvent.modifierFlags.contains(.command) {
            toggleSelection(for: block.id)
        } else if let onOpen {
            onOpen(block)
        } else {
            openWindow(value: block.id)
        }
    }

    private func toggleSelection(for blockId: String) {
        if listState.selectedBlockIds.contains(blockId) {
            listState.selectedBlockIds.remove(blockId)
            if listState.selectedBlockIds.isEmpty {
                listState.focusedBlockId = nil
            } else if listState.focusedBlockId == blockId {
                listState.focusedBlockId = listState.selectedBlockIds.first
            }
        } else {
            listState.selectedBlockIds.insert(blockId)
            listState.focusedBlockId = blockId
        }
    }
}

struct BlocksPane_Previews: PreviewProvider {
    static var previews: some View {
        BlocksPane(listState: BlocksListState())
            .environmentObject(BlocksViewModel())
    }
}
