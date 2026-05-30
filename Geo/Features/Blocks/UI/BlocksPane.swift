import SwiftUI
import AppKit

struct FocusRequest: Equatable {
    let blockId: String
    let token: UUID
}

struct BlocksPane: View {
    let externalFocus: FocusRequest?

    init(externalFocus: FocusRequest? = nil) {
        self.externalFocus = externalFocus
    }

    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.navigationStore) private var navigationStore
    @EnvironmentObject private var viewModel: BlocksViewModel
    @Environment(\.openWindow) var openWindow
    @State private var debouncedSearchText = ""
    @State private var searchDebounceWorkItem: DispatchWorkItem?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchResults: [BlockEntity] = []
    @State private var selectedBlockIds: Set<String> = []
    @State private var focusedBlockId: String?
    @State private var isTagCreationPresented = false
    @State private var newTagName = ""
    @State private var newTagColor: Color = .accentColor
    @State private var tagCreationError: String?
    @State private var selectedTagFilter: String? = nil
    @State private var hasTasksOnly = false
    @State private var statusFilter: BlockStatusFilter = .active
    @State private var selectedTypeFilter: BlockType? = nil
    @State private var selectedLayerFilter: BlockLayer? = nil
    @State private var pendingDeleteBlock: BlockEntity? = nil
    @AppStorage("blocksPane.groupingMode") private var groupingMode: GroupingMode = .none
    @AppStorage("blocksPane.sortField") private var sortField: BlockSortField = .created
    @AppStorage("blocksPane.sortOrder") private var sortOrder: BlockSortOrder = .newest
    @State private var tasks: [TaskItem] = []
    @State private var isTemplatePickerPresented = false
    @State private var isZettelkastenPickerPresented = false
    @AppStorage("blocksPane.collapsedFolders") private var collapsedFoldersRaw = ""
    @State private var knownFolders: [String] = []
    @State private var isFolderPromptPresented = false
    @State private var folderPromptTitle = "New Folder"
    @State private var folderPromptName = ""
    @State private var folderPromptAction: ((String) -> Void)? = nil

    var body: some View {
        Pane {
            blocksGrid
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $isTemplatePickerPresented) {
            TemplatePickerSheet { template in
                let expanded = TemplateService.shared.expandVariables(in: template.markdown, title: "")
                Task { @MainActor in
                    if let newBlock = await viewModel.createBlock(title: "", markdown: expanded.markdown) {
                        openWindow(value: newBlock.id)
                    }
                }
            }
            .environmentObject(TemplateService.shared)
        }
        .sheet(isPresented: $isZettelkastenPickerPresented) {
            ZettelkastenPickerSheet { template in
                createNewBlock(noteTemplate: template)
            }
        }
        .sheet(isPresented: $isTagCreationPresented) {
            TagCreationSheet(
                name: $newTagName,
                color: $newTagColor,
                errorMessage: tagCreationError,
                onCancel: { dismissTagCreation() },
                onCreate: { createTagFromSheet() }
            )
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
        .onChange(of: newTagName) {
            if tagCreationError != nil {
                tagCreationError = nil
            }
        }
        .task {
            viewModel.bindIfNeeded(
                blocksRepository: appEnvironment.blocksRepository,
                tagsRepository: appEnvironment.tagsRepository
            )
        }
        .task {
            for await observedTasks in appEnvironment.tasksRepository.observe() {
                await MainActor.run {
                    tasks = observedTasks
                }
            }
        }
    }
    
    private var filteredBlocks: [BlockEntity] {
        let base = viewModel.filteredBlocks(
            debouncedSearchText: debouncedSearchText,
            searchResults: searchResults,
            selectedTagFilter: selectedTagFilter,
            hasTasksOnly: hasTasksOnly,
            statusFilter: statusFilter,
            sortField: sortField,
            sortOrder: sortOrder,
            linkedPendingBlockIds: linkedPendingBlockIds
        )
        let typeFiltered: [BlockEntity]
        if let typeFilter = selectedTypeFilter {
            typeFiltered = base.filter { $0.metadata.type == typeFilter }
        } else {
            typeFiltered = base
        }
        guard let layerFilter = selectedLayerFilter else { return typeFiltered }
        return typeFiltered.filter { $0.metadata.layer == layerFilter }
    }

    private var linkedPendingBlockIds: Set<String> {
        let taskLinked = Set(tasks.filter { $0.status == .pending }.compactMap(\.linkedBlockId))
        let hasCheckboxes = Set(viewModel.blocks.filter { $0.markdown.contains("- [ ] ") }.map(\.id))
        return taskLinked.union(hasCheckboxes)
    }

    private var targetBlockIds: [String] {
        if !selectedBlockIds.isEmpty {
            return Array(selectedBlockIds)
        }
        if let focused = focusedBlockId {
            return [focused]
        }
        return []
    }

    private var blockGroups: [BlockGroup] {
        viewModel.blockGroups(
            for: filteredBlocks,
            groupingMode: groupingMode,
            sortField: sortField,
            sortOrder: sortOrder
        )
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

    private var blocksGrid: some View {
        VStack(spacing: 0) {
            BlocksControlBar(
                groupingMode: $groupingMode,
                sortField: $sortField,
                sortOrder: $sortOrder,
                selectedTagFilter: $selectedTagFilter,
                hasTasksOnly: $hasTasksOnly,
                statusFilter: $statusFilter,
                selectedTypeFilter: $selectedTypeFilter,
                selectedLayerFilter: $selectedLayerFilter,
                tags: viewModel.tags,
                selectionCount: selectedBlockIds.count,
                onCreateNote: { createNewBlock(template: .blank) },
                onCreateFromTemplate: { isTemplatePickerPresented = true },
                onCreateZettelkasten: { isZettelkastenPickerPresented = true },
                onCreateTag: { presentTagCreation() },
                searchText: Binding(
                    get: { navigationStore.searchTexts[.nodes] ?? "" },
                    set: { navigationStore.searchTexts[.nodes] = $0 }
                ),
                onTagSelected: { presentTagCreation() },
                onDeleteSelected: { deleteSelectedBlocks() },
                onClearSelection: { selectedBlockIds.removeAll() }
            )
            ScrollView {
                if !viewModel.hasLoadedInitialSnapshot {
                    loadingState
                } else if viewModel.blocks.isEmpty {
                    emptyState
                } else if filteredBlocks.isEmpty {
                    filteredEmptyState
                } else {
                    blocksGridContent
                }
            }
        }
        .onTapGesture {
            if !selectedBlockIds.isEmpty {
                selectedBlockIds.removeAll()
            }
            focusedBlockId = nil
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
            focusedBlockId = id
            selectedBlockIds = [id]
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
        for block in filteredBlocks {
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

    private var blocksGridContent: some View {
        Group {
            if groupingMode == .none {
                LazyVStack(spacing: 1) {
                    ForEach(filteredBlocks) { block in
                        blockRow(for: block)
                    }
                }
            } else if groupingMode == .folder {
                LazyVStack(spacing: 1) {
                    FolderTreeRows(
                        node: viewModel.folderTree(for: filteredBlocks, extraFolders: knownFolders),
                        depth: 0,
                        collapsed: collapsedFolders,
                        onToggle: toggleFolder,
                        blockRow: { AnyView(blockRow(for: $0)) },
                        onNewBlock: { newBlock(inFolder: $0) },
                        onNewSubfolder: { parent in
                            promptFolderName(title: "New Subfolder") { createSubfolder(parent: parent, name: $0) }
                        }
                    )
                }
            } else {
                LazyVStack(spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(blockGroups) { group in
                        Section {
                            ForEach(group.blocks) { block in
                                blockRow(for: block)
                            }
                        } header: {
                            BlockGroupHeader(title: group.title, count: group.blocks.count, color: group.color)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, GeoStyle.Spacing.editorPadding)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: groupingMode)
    }

    private func blockRow(for block: BlockEntity) -> some View {
        let linkedTaskCount = tasks.reduce(into: 0) { count, task in
            if task.status == .pending, task.linkedBlockId == block.id {
                count += 1
            }
        }
        return Button {
            handleBlockClick(block)
        } label: {
            BlockListRow(
                block: block,
                tag: viewModel.tag(for: block.tagId),
                linkedTaskCount: linkedTaskCount,
                isSelected: selectedBlockIds.contains(block.id)
            )
        }
        .contentShape(Rectangle())
        .accessibilityLabel(block.displayTitle.isEmpty ? "Untitled block" : block.displayTitle)
        .accessibilityHint("Double-tap to open editor")
        .plainNoFocusButton()
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
        .frame(
            maxWidth: .infinity, 
            maxHeight: .infinity,
            )
        .padding()
    }
    
    private var filteredEmptyState: some View {
        let hasSearch = !debouncedSearchText.isEmpty
        let hasFilters = selectedTagFilter != nil || hasTasksOnly || statusFilter != .active || selectedTypeFilter != nil || selectedLayerFilter != nil

        return VStack(spacing: 12) {
            Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.5))
            Text(hasSearch ? "No search results" : hasFilters ? "No matching blocks" : "No blocks found")
                .font(.title3.weight(.semibold))
                .foregroundColor(.secondary)
            Text(hasSearch ? "Try a different keyword." : hasFilters ? "Try adjusting your filters." : "Create a new block to get started.")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.8))
            if hasSearch || hasFilters {
                Button(hasSearch ? "Clear Search" : "Clear Filters") {
                    navigationStore.searchText = ""
                    selectedTagFilter = nil
                    hasTasksOnly = false
                    statusFilter = .active
                    selectedTypeFilter = nil
                    selectedLayerFilter = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private func createNewBlock(template: BlockTemplate) {
        let payload = template.make()
        Task { @MainActor in
            if let newBlock = await viewModel.createBlock(title: payload.title, markdown: payload.markdown) {
                openWindow(value: newBlock.id)
            }
        }
    }

    private func createNewBlock(noteTemplate: NoteTemplate?) {
        let markdown = noteTemplate?.content ?? ""
        Task { @MainActor in
            guard let newBlock = await viewModel.createBlock(title: "", markdown: markdown) else { return }
            if let template = noteTemplate {
                let metadata = template.initialMetadata
                _ = await viewModel.setType(metadata.type, for: newBlock.id)
                if let status = metadata.status {
                    _ = await viewModel.setStatus(status, for: newBlock.id)
                }
            }
            openWindow(value: newBlock.id)
        }
    }
    
    private func handleBlockClick(_ block: BlockEntity) {
        focusedBlockId = block.id
        if NSEvent.modifierFlags.contains(.command) {
            toggleSelection(for: block.id)
        } else {
            openWindow(value: block.id)
        }
    }
    
    private func toggleSelection(for blockId: String) {
        if selectedBlockIds.contains(blockId) {
            selectedBlockIds.remove(blockId)
            if selectedBlockIds.isEmpty {
                focusedBlockId = nil
            } else if focusedBlockId == blockId {
                focusedBlockId = selectedBlockIds.first
            }
        } else {
            selectedBlockIds.insert(blockId)
            focusedBlockId = blockId
        }
    }

    private func assignTag(_ tagId: String?) {
        let targets = targetBlockIds
        guard !targets.isEmpty else { return }
        Task {
            for blockId in targets {
                _ = await viewModel.setTag(tagId, for: blockId)
            }
        }
    }

    private func presentTagCreation() {
        newTagName = ""
        newTagColor = .accentColor
        tagCreationError = nil
        isTagCreationPresented = true
    }

    private func dismissTagCreation() {
        isTagCreationPresented = false
        tagCreationError = nil
    }

    private func createTagFromSheet() {
        let color = TagColor(color: newTagColor)
        Task {
            let result = await viewModel.createTag(name: newTagName, color: color)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                switch result {
                case .success(let tag):
                    if !targetBlockIds.isEmpty {
                        assignTag(tag.id)
                    }
                    dismissTagCreation()
                case .failure(let error):
                    tagCreationError = errorDescription(for: error)
                }
            }
        }
    }

    private func errorDescription(for error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return "Unable to save tag."
    }

    private func deleteSelectedBlocks() {
        let blocksToDelete = viewModel.blocks.filter { selectedBlockIds.contains($0.id) }
        Task { @MainActor in
            for block in blocksToDelete {
                _ = await viewModel.deleteBlock(id: block.id)
            }
            selectedBlockIds.removeAll()
            focusedBlockId = nil
        }
    }
}

private struct BlocksControlBar: View {
    @Binding var groupingMode: GroupingMode
    @Binding var sortField: BlockSortField
    @Binding var sortOrder: BlockSortOrder
    @Binding var selectedTagFilter: String?
    @Binding var hasTasksOnly: Bool
    @Binding var statusFilter: BlockStatusFilter
    @Binding var selectedTypeFilter: BlockType?
    @Binding var selectedLayerFilter: BlockLayer?
    let tags: [Tag]
    let selectionCount: Int
    let onCreateNote: () -> Void
    let onCreateFromTemplate: () -> Void
    let onCreateZettelkasten: () -> Void
    let onCreateTag: () -> Void
    @Binding var searchText: String
    let onTagSelected: () -> Void
    let onDeleteSelected: () -> Void
    let onClearSelection: () -> Void

    @State private var isSearchExpanded = false
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if selectionCount == 0 {
                        newMenu
                        searchControl
                        groupMenu
                        sortMenu
                        tagMenu
                        viewMenu
                        statusMenu
                        if isAnyFilterActive {
                            clearChip
                        }
                    } else {
                        selectionBadge
                        tagSelectedChip
                        deleteSelectedChip
                        clearSelectionChip
                    }
                }
                .padding(.horizontal, GeoStyle.Spacing.editorPadding)
                .padding(.vertical, 12)
                .frame(minWidth: geo.size.width, alignment: .leading)
            }
        }
        .frame(height: 56)
    }

    private var isAnyFilterActive: Bool {
        selectedTagFilter != nil || hasTasksOnly || groupingMode != .none || statusFilter != .active || selectedTypeFilter != nil || selectedLayerFilter != nil
    }

    private var newMenu: some View {
        chipMenu(icon: "plus", text: "New", active: false) {
            Button {
                onCreateNote()
            } label: {
                Label("Create Note", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            Button {
                onCreateFromTemplate()
            } label: {
                Label("From Template", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Button {
                onCreateZettelkasten()
            } label: {
                Label("Zettelkasten", systemImage: "books.vertical.fill")
            }
            .keyboardShortcut("z", modifiers: .command)
        }
    }

    @ViewBuilder
    private var searchControl: some View {
        if isSearchExpanded {
            searchField
        } else {
            searchIconButton
        }
    }

    private var searchIconButton: some View {
        Button {
            expandSearch()
        } label: {
            chipLabel(icon: "magnifyingglass", text: nil, showChevron: false, active: false)
        }
        .buttonStyle(.plain)
        .chipShell(active: false, iconOnly: true)
        .keyboardShortcut("f", modifiers: .command)
        .help("Search")
        .accessibilityLabel("Search")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
                .focused($isSearchFieldFocused)
                .onSubmit { isSearchFieldFocused = false }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                collapseSearch()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close search")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(Color.primary.opacity(0.05))
        )
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        )
        .fixedSize()
    }

    private func expandSearch() {
        isSearchExpanded = true
        DispatchQueue.main.async {
            isSearchFieldFocused = true
        }
    }

    private func collapseSearch() {
        searchText = ""
        isSearchFieldFocused = false
        isSearchExpanded = false
    }

    private var selectionBadge: some View {
        Text("\(selectionCount) selected")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
    }

    private var tagSelectedChip: some View {
        Button(action: onTagSelected) {
            chipLabel(icon: "tag.fill", text: "Tag", showChevron: false, active: false)
        }
        .buttonStyle(.plain)
        .chipShell(active: false)
        .keyboardShortcut("t", modifiers: .command)
    }

    private var deleteSelectedChip: some View {
        Button(action: onDeleteSelected) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                Text("Delete")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.red)
        }
        .buttonStyle(.plain)
        .chipShell(active: false)
        .keyboardShortcut("d", modifiers: .command)
    }

    private var clearSelectionChip: some View {
        Button(action: onClearSelection) {
            chipLabel(icon: "xmark.circle", text: "Done", showChevron: false, active: false)
        }
        .buttonStyle(.plain)
        .chipShell(active: false)
        .keyboardShortcut(.escape, modifiers: [])
    }

    private var groupMenu: some View {
        chipMenu(
            icon: "square.grid.2x2",
            text: groupingMode == .none ? "Group" : groupingMode.label,
            active: groupingMode != .none
        ) {
            ForEach(GroupingMode.allCases) { mode in
                pickerRow(label: mode.label, selected: groupingMode == mode) {
                    groupingMode = mode
                }
            }
        }
    }

    private var sortMenu: some View {
        chipMenu(icon: "arrow.up.arrow.down", text: sortField.label, active: false) {
            Button {
                sortOrder.toggle()
            } label: {
                Label(sortOrder.label, systemImage: sortOrder.systemImageName)
            }
            Divider()
            ForEach(BlockSortField.allCases) { field in
                pickerRow(label: field.label, selected: sortField == field) {
                    sortField = field
                }
            }
        }
    }

    private var tagMenu: some View {
        chipMenu(icon: "tag", text: tagMenuText, active: selectedTagFilter != nil) {
            Button {
                onCreateTag()
            } label: {
                Label("New Tag…", systemImage: "plus")
            }
            .keyboardShortcut("t", modifiers: .command)
            Divider()
            pickerRow(label: "All", selected: selectedTagFilter == nil) {
                selectedTagFilter = nil
            }
            pickerRow(label: "Untagged", selected: selectedTagFilter == "untagged") {
                selectedTagFilter = "untagged"
            }
            if !tags.isEmpty {
                Divider()
                ForEach(tags) { tag in
                    pickerRow(label: tag.name, selected: selectedTagFilter == tag.id) {
                        selectedTagFilter = tag.id
                    }
                }
            }
        }
    }

    private var tagMenuText: String {
        guard let id = selectedTagFilter else { return "Tag" }
        if id == "untagged" { return "Untagged" }
        return tags.first(where: { $0.id == id })?.name ?? "Tag"
    }

    private var viewMenu: some View {
        chipMenu(
            icon: viewMenuIcon,
            text: viewMenuText,
            active: selectedTypeFilter != nil || selectedLayerFilter != nil
        ) {
            Section("Tipo") {
                pickerRow(label: "All", selected: selectedTypeFilter == nil) {
                    selectedTypeFilter = nil
                }
                ForEach(BlockType.allCases, id: \.self) { type in
                    pickerRow(
                        label: type.displayName,
                        icon: type.icon,
                        selected: selectedTypeFilter == type
                    ) {
                        selectedTypeFilter = type
                    }
                }
            }
            Section("Camada") {
                pickerRow(label: "All", selected: selectedLayerFilter == nil) {
                    selectedLayerFilter = nil
                }
                ForEach(BlockLayer.allCases, id: \.self) { layer in
                    pickerRow(
                        label: layer.displayName,
                        icon: layer.icon,
                        selected: selectedLayerFilter == layer
                    ) {
                        selectedLayerFilter = layer
                    }
                }
            }
        }
    }

    private var viewMenuIcon: String {
        if let type = selectedTypeFilter { return type.icon }
        if let layer = selectedLayerFilter { return layer.icon }
        return "square.stack.3d.up"
    }

    private var viewMenuText: String {
        switch (selectedTypeFilter, selectedLayerFilter) {
        case (nil, nil): return "View"
        case let (type?, nil): return type.displayName
        case let (nil, layer?): return layer.displayName
        case let (type?, layer?): return "\(type.displayName) · \(layer.displayName)"
        }
    }

    private var statusMenu: some View {
        chipMenu(
            icon: statusFilter.iconName,
            text: statusFilter.chipText,
            active: statusFilter != .active || hasTasksOnly
        ) {
            Button {
                hasTasksOnly.toggle()
            } label: {
                Label("With Tasks", systemImage: hasTasksOnly ? "checkmark.circle.fill" : "checkmark.circle")
            }
            Divider()
            ForEach(BlockStatusFilter.allCases) { option in
                pickerRow(label: option.label, selected: statusFilter == option) {
                    statusFilter = option
                }
            }
        }
    }

    private var clearChip: some View {
        Button {
            selectedTagFilter = nil
            hasTasksOnly = false
            groupingMode = .none
            statusFilter = .active
            selectedTypeFilter = nil
            selectedLayerFilter = nil
        } label: {
            chipLabel(icon: "xmark.circle.fill", text: "Clear", showChevron: false, active: false)
        }
        .buttonStyle(.plain)
        .chipShell(active: false)
        .opacity(0.75)
    }

    @ViewBuilder
    private func chipLabel(icon: String?, text: String?, showChevron: Bool, active: Bool) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
            }
            if let text {
                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            }
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .foregroundColor(active ? .white : .primary)
    }

    private func chipMenu<Content: View>(
        icon: String,
        text: String,
        active: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            chipLabel(icon: icon, text: text, showChevron: true, active: active)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .chipShell(active: active)
    }

    private func pickerRow(
        label: String,
        icon: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if selected {
                Label(label, systemImage: "checkmark")
            } else if let icon {
                Label(label, systemImage: icon)
            } else {
                Text(label)
            }
        }
    }
}

private extension View {
    func chipShell(active: Bool, iconOnly: Bool = false) -> some View {
        self
            .padding(.horizontal, iconOnly ? 12 : 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(active ? Color.accentColor : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        active ? Color.clear : Color.primary.opacity(0.18),
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
    }
}

private struct BlockGroupHeader: View {
    let title: String
    let count: Int
    let color: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let color {
                Circle()
                    .fill(color)
                    .overlay(Circle().stroke(Color(.separatorColor), lineWidth: 0.5))
                    .frame(width: 8, height: 8)
            }
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(.secondarySystemFill))
                .clipShape(Capsule())
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
    }
}

struct TagCreationSheet: View {
    @Binding var name: String
    @Binding var color: Color
    let errorMessage: String?
    let onCancel: () -> Void
    let onCreate: () -> Void

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Tag")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            ColorPicker("Color", selection: $color, supportsOpacity: false)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

private struct BlockListRow: View {
    let block: BlockEntity
    let tag: Tag?
    let linkedTaskCount: Int
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tag?.color.swiftUIColor ?? Color(.separatorColor).opacity(0.4))
                .frame(width: 8, height: 8)

            Text(block.displayTitle.isEmpty ? "Untitled" : block.displayTitle)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if linkedTaskCount > 0 {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
            }

            Spacer(minLength: 12)

            Text("\(block.metadata.type.displayName.lowercased()) · \(block.metadata.layer.displayName.lowercased())")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            Text(Self.dateFormatter.string(from: block.lastEdited))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 54, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var rowFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if isHovered {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }

    private static var dateFormatter: DateFormatter { DateFormatters.monthDay }
}


enum BlockStatusFilter: String, CaseIterable, Identifiable {
    case active
    case evergreen
    case all
    case archived
    case draft

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var chipText: String { self == .active ? "Status" : label }

    var iconName: String {
        switch self {
        case .active: return "circle.dashed"
        case .evergreen: return "leaf.fill"
        case .all: return "circle.grid.2x2"
        case .archived: return "archivebox"
        case .draft: return "pencil.line"
        }
    }

    func includes(status: String?) -> Bool {
        if self == .all { return true }
        let trimmed = (status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).flatMap { $0.isEmpty ? nil : $0 }
        return (trimmed ?? "active") == rawValue
    }
}

enum BlockTemplate {
    case blank
    case todo

    func make() -> (title: String, markdown: String) {
        switch self {
        case .blank:
            return ("", "")
        case .todo:
            return ("New Todo", "- [ ] ")
        }
    }
}


struct ZettelkastenPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (NoteTemplate?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nova nota")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            VStack(spacing: 0) {
                ForEach(NoteTemplate.allCases) { template in
                    optionRow(
                        icon: template.icon,
                        title: template.displayName,
                        subtitle: subtitle(for: template),
                        action: {
                            onSelect(template)
                            dismiss()
                        }
                    )
                }
                optionRow(
                    icon: "doc",
                    title: "Em branco",
                    subtitle: "Sem template",
                    action: {
                        onSelect(nil)
                        dismiss()
                    }
                )
            }
            .padding(.vertical, 4)
        }
        .frame(width: 380)
    }

    private func subtitle(for template: NoteTemplate) -> String {
        switch template {
        case .permanent: return "Uma ideia evergreen"
        case .project: return "Trabalho em andamento com objetivo"
        case .moc: return "Map of Content — índice temático"
        case .literature: return "Citação ou fonte externa"
        }
    }

    private func optionRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(GeoStyle.Colors.geoBlue)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .plainNoFocusButton()
    }
}

struct BlocksPane_Previews: PreviewProvider {
    static var previews: some View {
        BlocksPane()
            .environmentObject(BlocksViewModel())
    }
}
