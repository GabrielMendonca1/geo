import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import os.log

struct BlockEditorView: View, Equatable {
    static func == (lhs: BlockEditorView, rhs: BlockEditorView) -> Bool {
        lhs.block.id == rhs.block.id && lhs.actions === rhs.actions
    }

    let block: BlockEntity
    let actions: BlockEditorActions
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.openWindow) var openWindow

    @State private var liveBlock: BlockEntity

    @State private var document: BlockEditorDocument?
    @State private var autosaveController = BlockEditorAutosaveController()
    @State private var hasLoadedContent = false
    @State private var isDirty = false
    @State private var lastSyncedEdit: Date?
    @State private var lastSyncedEditGeneration: UInt64 = 0

    @State private var isAlwaysOnTop: Bool = false
    @State private var isFullWidth: Bool = false
    @AppStorage(EditorTypographyPreferences.fontSizeKey)
    private var editorBaseFontSize = EditorTypographyPreferences.defaultSize
    @State private var window: NSWindow?
    @State private var windowSize: CGSize = .zero
    @State private var isTitleBarHovered = false
    @State private var titleBarTracker: TitleBarHoverTracker?

    @State private var isTagMenuPresented = false
    @State private var isOutlinePresented = false
    @State private var isTagCreationPresented = false
    @State private var newTagName = ""
    @State private var newTagColor: Color = .accentColor
    @State private var tagCreationError: String?

    @State private var isBacklinksPanelExpanded = false
    @State private var backlinks: [BacklinkItem] = []
    @State private var backlinksTask: Task<Void, Never>?
    @State private var backlinksRefreshTask: Task<Void, Never>?
    @State private var isArchiveProjectSheetPresented = false

    @State private var statusBarWords: Int = 0
    @State private var statusBarMinutes: Int = 0
    @State private var statusBarRecomputeTask: Task<Void, Never>?

    @State private var wikiLinkSuggestions: [WikiLinkSuggestionItem] = []
    @State private var mentionableBlocks: [BlockMentionItem] = []

    init(block: BlockEntity, actions: BlockEditorActions) {
        self.block = block
        self.actions = actions
        _liveBlock = State(initialValue: block)
    }

    private var responsiveLayout: ResponsiveLayout {
        ResponsiveLayout(windowSize: windowSize)
    }

    private var effectiveEditorFontSize: CGFloat {
        let clampedBaseSize = EditorTypographyPreferences.clampedSize(editorBaseFontSize)
        let responsiveScale = responsiveLayout.editorFontSize / GeoStyle.Typography.editorFontSize
        return CGFloat(clampedBaseSize) * responsiveScale
    }

    var body: some View {
        editorBody
            .modifier(BlockEditorChangeHandlers(
                window: $window,
                configureHoverMonitor: configureHoverMonitor,
                flushSave: flushSave,
                removeHoverMonitor: removeHoverMonitor,
                loadContent: loadContent
            ))
            .onReceive(actions.focusedBlockPublisher) { newBlock in
                if let newBlock { liveBlock = newBlock }
            }
            .onChange(of: isFullWidth) { _, newValue in
                guard newValue != liveBlock.metadata.isFullWidth else { return }
                Task { _ = await actions.setFullWidth(liveBlock.id, newValue) }
            }
            .onChange(of: liveBlock.metadata.isFullWidth) { _, newValue in
                if isFullWidth != newValue { isFullWidth = newValue }
            }
            .onChange(of: liveBlock.lastEdited) { _, newDate in
                guard let document else { return }
                guard lastSyncedEdit != newDate else { return }
                guard !isDirty else { return }
                guard document.editGeneration == lastSyncedEditGeneration else { return }
                let storeMarkdown = liveBlock.markdown
                let localMarkdown = document.serialize()
                guard storeMarkdown != localMarkdown else {
                    lastSyncedEdit = newDate
                    return
                }
                document.loadMarkdown(storeMarkdown)
                lastSyncedEdit = newDate
                lastSyncedEditGeneration = document.editGeneration
            }
            .task {
                await loadBacklinks()
            }
            .onChange(of: liveBlock.displayTitle) { _, _ in
                scheduleBacklinksRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .geoPendingAnchorChanged)) { note in
                guard (note.object as? String) == block.id else { return }
                consumePendingAnchor()
            }
            .onAppear {
                refreshSuggestionCaches()
                scheduleStatusBarRecompute(immediate: true)
            }
            .onReceive(actions.blocksCountPublisher) { _ in
                refreshSuggestionCaches()
            }
            .onChange(of: liveBlock.markdown) { _, _ in
                scheduleStatusBarRecompute(immediate: false)
            }
            .onDisappear {
                backlinksTask?.cancel()
                backlinksRefreshTask?.cancel()
                statusBarRecomputeTask?.cancel()
            }
    }

    private var editorBody: some View {
        ZStack(alignment: .top) {
            Palette.background
                .padding(.top, TitleBarMetrics.stripHeight)

            editorContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, TitleBarMetrics.stripHeight)
                .readSize { newSize in
                    windowSize = newSize
                }

            BlockEditorTitleBarOverlay(
                isAlwaysOnTop: $isAlwaysOnTop,
                isFullWidth: $isFullWidth,
                isVisible: isTitleBarHovered,
                tag: currentTag,
                isTagMenuPresented: $isTagMenuPresented,
                isOutlinePresented: $isOutlinePresented,
                tagSelectionMenu: { AnyView(tagSelectionMenu.frame(minWidth: 200)) },
                outlinePopover: {
                    AnyView(
                        OutlinePopover(headings: outlineHeadings) { blockId in
                            document?.focusRequest = BlockFocusRequest(blockId: blockId, cursorOffset: 0)
                        }
                    )
                },
                typeChip: { typePickerChip },
                layerChip: { layerPickerChip },
                lifecycleChip: { lifecycleActionChip }
            )
        }
        .ignoresSafeArea()
        .navigationTitle("")
        .clipShape(RoundedRectangle(cornerRadius: GeoStyle.Layout.windowCornerRadius, style: .continuous))
        .geoWindowChrome(window: $window)
        .sheet(isPresented: $isTagCreationPresented) {
            TagCreationSheet(
                name: $newTagName,
                color: $newTagColor,
                errorMessage: tagCreationError,
                onCancel: {
                    isTagCreationPresented = false
                    tagCreationError = nil
                },
                onCreate: { createTagFromSheet() }
            )
        }
        .sheet(isPresented: $isArchiveProjectSheetPresented) {
            ArchiveProjectSheet(
                projectTitle: liveBlock.displayTitle,
                onCancel: { isArchiveProjectSheetPresented = false },
                onExtractPermanent: { handleExtractPermanent() },
                onArchiveOnly: { handleArchiveOnly() }
            )
        }
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            BlockLinkedSchedulesHeader(
                blockId: block.id,
                horizontalPadding: responsiveLayout.editorPaddingHorizontal
            )
            .padding(.top, 12)

            Group {
                if let document {
                    BlockListView(
                        document: document,
                        fontSize: effectiveEditorFontSize,
                        horizontalPadding: responsiveLayout.editorPaddingHorizontal,
                        verticalPadding: responsiveLayout.editorPaddingVertical,
                        contentMaxWidth: isFullWidth ? .infinity : 720,
                        contentBaseURL: liveBlock.url.deletingLastPathComponent(),
                        accentColor: currentTag?.color.swiftUIColor,
                        attachmentHandler: { pasteboard, textView in
                            let handler = AttachmentHandler(
                                blockURL: liveBlock.url,
                                attachmentService: appEnvironment.attachmentService
                            )
                            let result = handler.handlePaste(from: pasteboard, in: textView)
                            if result {
                                immediateSave()
                            }
                            return result
                        },
                        mentionableBlocks: mentionableBlocks,
                        onWikiLinkClicked: { payload in
                            let normalizedTarget = WikiTitleNormalizer.normalize(payload.target)
                            let match = actions.resolveBlockByTitle(normalizedTarget)
                            guard let match else { return }
                            if let anchor = payload.anchor {
                                PendingAnchorStore.shared.enqueue(blockId: match.id, anchor: anchor)
                            }
                            openWindow(id: "editor", value: match.id)
                        }
                    )
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if liveBlock.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(typePlaceholder)
                        .font(.system(size: effectiveEditorFontSize))
                        .foregroundColor(Palette.tertiaryForeground.opacity(0.6))
                        .padding(.horizontal, responsiveLayout.editorPaddingHorizontal)
                        .padding(.top, responsiveLayout.editorPaddingVertical)
                        .allowsHitTesting(false)
                }
            }
            .background(
                WikiLinkAutocompleteAttachment(titles: wikiLinkSuggestions)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            )

            if statusBarWords > 0 {
                EditorStatusBar(words: statusBarWords, minutes: statusBarMinutes)
                    .equatable()
                    .padding(.horizontal, responsiveLayout.editorPaddingHorizontal)
                    .padding(.vertical, 6)
            }

            if !backlinks.isEmpty {
                BacklinksPanel(
                    blockTitle: liveBlock.displayTitle,
                    isExpanded: isBacklinksPanelExpanded,
                    backlinks: backlinks,
                    onToggle: { isBacklinksPanelExpanded.toggle() },
                    onOpenBlock: { id in openWindow(value: id) }
                )
            }
        }
    }
}

private extension BlockEditorView {

    var currentTag: Tag? {
        actions.resolvedTag(liveBlock)
    }

    func isCurrentTag(_ tag: Tag) -> Bool {
        guard let current = currentTag else { return false }
        return TagStore.canonicalName(current.name) == TagStore.canonicalName(tag.name)
    }

    var outlineHeadings: [OutlineHeading] {
        OutlineExtractor.headings(from: document?.blocks ?? [])
    }

    var tagSelectionMenu: some View {
        let availableTags = actions.allTags()
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tag")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    tagMenuItem(tag: nil, isSelected: currentTag == nil)

                    if !availableTags.isEmpty {
                        Divider()
                            .padding(.vertical, 4)

                        ForEach(availableTags) { tag in
                            tagMenuItem(tag: tag, isSelected: isCurrentTag(tag))
                        }
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider()

            Button {
                isTagMenuPresented = false
                newTagName = ""
                newTagColor = .accentColor
                tagCreationError = nil
                isTagCreationPresented = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("New Tag...")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .plainNoFocusButton()
        }
        .frame(width: 220)
    }

    func tagMenuItem(tag: Tag?, isSelected: Bool) -> some View {
        Button {
            let tagId = tag?.id
            Task { _ = await actions.setTag(liveBlock.id, tagId) }
            isTagMenuPresented = false
        } label: {
            HStack(spacing: 8) {
                if let tag {
                    Circle()
                        .fill(tag.color.swiftUIColor)
                        .overlay(Circle().stroke(Palette.border, lineWidth: 0.5))
                        .frame(width: 10, height: 10)
                    Text(tag.name)
                } else {
                    Circle()
                        .fill(Palette.tertiaryForeground.opacity(0.3))
                        .frame(width: 10, height: 10)
                    Text("No Tag")
                        .foregroundColor(Palette.tertiaryForeground)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Palette.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isSelected ? Palette.accent.opacity(0.1) : Color.clear)
        }
        .plainNoFocusButton()
    }

}

private extension BlockEditorView {
    var currentBlockType: BlockType {
        liveBlock.metadata.type
    }

    var currentBlockLayer: BlockLayer {
        liveBlock.metadata.layer
    }

    var typePlaceholder: String {
        switch currentBlockType {
        case .permanent:
            return "Uma afirmação completa…"
        case .project:
            return "Nome do projeto…"
        case .moc:
            return "MOC — tema…"
        case .fleeting:
            return "Captura rápida…"
        case .literature:
            return "Literatura — fonte…"
        }
    }

    var typePickerChip: some View {
        Menu {
            ForEach(BlockType.allCases, id: \.self) { type in
                Button {
                    handleTypeSelection(type)
                } label: {
                    Label(
                        type.displayName,
                        systemImage: currentBlockType == type ? "checkmark" : type.icon
                    )
                }
            }
        } label: {
            chipLabel(icon: currentBlockType.icon, text: currentBlockType.displayName, showChevron: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
    }

    func handleTypeSelection(_ type: BlockType) {
        guard type != currentBlockType else { return }
        Task { _ = await actions.setType(liveBlock.id, type) }
    }

    var layerPickerChip: some View {
        Menu {
            ForEach(BlockLayer.allCases, id: \.self) { layer in
                Button {
                    Task { _ = await actions.setLayer(liveBlock.id, layer) }
                } label: {
                    Label(
                        layer.displayName,
                        systemImage: currentBlockLayer == layer ? "checkmark" : layer.icon
                    )
                }
            }
        } label: {
            chipLabel(icon: currentBlockLayer.icon, text: currentBlockLayer.displayName, showChevron: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help("Camada de escrita")
    }

    @ViewBuilder
    var lifecycleActionChip: some View {
        switch currentBlockType {
        case .project:
            Button {
                isArchiveProjectSheetPresented = true
            } label: {
                chipLabel(icon: "archivebox", text: "Arquivar projeto", showChevron: false)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Arquivar projeto, opcionalmente extraindo uma permanent note")
        case .fleeting, .literature:
            Button {
                promoteToPermanent()
            } label: {
                chipLabel(icon: "arrow.up.forward.circle", text: "Promover pra permanent", showChevron: false)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Refine o título — uma afirmação completa")
        case .permanent, .moc:
            EmptyView()
        }
    }

    func chipLabel(icon: String, text: String, showChevron: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .foregroundColor(Palette.tertiaryForeground)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Palette.border.opacity(0.5), lineWidth: 0.5))
        .contentShape(Capsule())
        .pointingHandCursor()
    }

    func handleExtractPermanent() {
        let project = liveBlock
        Task { @MainActor in
            let lifecycle = actions.lifecycleActions()
            if let newBlock = await lifecycle.extractPermanent(from: project) {
                openWindow(value: newBlock.id)
            }
            isArchiveProjectSheetPresented = false
        }
    }

    func handleArchiveOnly() {
        let id = liveBlock.id
        Task { @MainActor in
            let lifecycle = actions.lifecycleActions()
            _ = await lifecycle.archiveProject(blockId: id)
            isArchiveProjectSheetPresented = false
        }
    }

    func promoteToPermanent() {
        let id = liveBlock.id
        Task { @MainActor in
            let lifecycle = actions.lifecycleActions()
            _ = await lifecycle.promoteToPermanent(blockId: id)
        }
    }
}

private extension BlockEditorView {
    func loadContent() {
        guard !hasLoadedContent else { return }
        hasLoadedContent = true

        let doc = BlockEditorDocument(markdown: block.markdown)
        let seededBlockId = doc.seedEmptyParagraphIfNeeded()
        doc.onDirty = { [weak autosaveController] in
            if !isDirty { isDirty = true }
            autosaveController?.schedule(delay: 0.5) {
                Task { @MainActor in
                    await save()
                }
            }
        }
        if let anchor = PendingAnchorStore.shared.consume(blockId: block.id),
           let headingBlockId = headingMatch(anchor: anchor, in: doc.blocks) {
            doc.focusRequest = BlockFocusRequest(blockId: headingBlockId, cursorOffset: 0)
        } else if let seededBlockId {
            doc.focusRequest = BlockFocusRequest(blockId: seededBlockId, cursorOffset: 0)
        }
        document = doc
        lastSyncedEdit = block.lastEdited
        lastSyncedEditGeneration = doc.editGeneration
        isFullWidth = block.metadata.isFullWidth
        actions.setFocusedBlock(block.id)
    }

    func headingMatch(anchor: String, in blocks: [EditorBlock]) -> UUID? {
        let normalized = Self.normalizeHeading(anchor)
        guard !normalized.isEmpty else { return nil }
        for editorBlock in blocks {
            guard case .heading = editorBlock.kind else { continue }
            let title = Self.normalizeHeading(editorBlock.cleanContent ?? editorBlock.content)
            if title == normalized {
                return editorBlock.id
            }
        }
        return nil
    }

    func consumePendingAnchor() {
        guard let document else { return }
        guard let anchor = PendingAnchorStore.shared.consume(blockId: block.id) else { return }
        guard let headingBlockId = headingMatch(anchor: anchor, in: document.blocks) else { return }
        document.focusRequest = BlockFocusRequest(blockId: headingBlockId, cursorOffset: 0)
    }
}

extension BlockEditorView {
    static func normalizeHeading(_ s: String) -> String {
        let stripped = stripInlineMarkdown(s)
        return stripped
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
    }

    static func stripInlineMarkdown(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "***", with: "")
        out = out.replacingOccurrences(of: "**", with: "")
        out = out.replacingOccurrences(of: "__", with: "")
        out = out.replacingOccurrences(of: "*", with: "")
        out = out.replacingOccurrences(of: "_", with: "")
        out = out.replacingOccurrences(of: "`", with: "")
        out = out.replacingOccurrences(of: "~~", with: "")
        return out
    }
}

private extension BlockEditorView {
    func flushSave() {
        autosaveController.flush {
            let newMarkdown = buildMarkdown()
            let snapshotGeneration = document?.editGeneration ?? 0
            guard newMarkdown != liveBlock.markdown else {
                isDirty = false
                return
            }
            actions.saveBlockSync(liveBlock.id, newMarkdown)
            isDirty = false
            lastSyncedEdit = liveBlock.lastEdited
            lastSyncedEditGeneration = snapshotGeneration
        }
        actions.clearFocusedBlock(liveBlock.id)
    }

    func immediateSave() {
        autosaveController.cancel()
        let newMarkdown = buildMarkdown()
        let snapshotGeneration = document?.editGeneration ?? 0
        guard newMarkdown != liveBlock.markdown else {
            isDirty = false
            return
        }
        actions.saveBlockSync(liveBlock.id, newMarkdown)
        isDirty = false
        lastSyncedEdit = liveBlock.lastEdited
        lastSyncedEditGeneration = snapshotGeneration
    }

    func save() async {
        autosaveController.cancel()
        let newMarkdown = buildMarkdown()
        let snapshotGeneration = document?.editGeneration ?? 0
        guard newMarkdown != liveBlock.markdown else {
            isDirty = false
            return
        }
        _ = await actions.updateBlock(liveBlock.id, newMarkdown)
        isDirty = false
        lastSyncedEdit = liveBlock.lastEdited
        lastSyncedEditGeneration = snapshotGeneration
    }

    func configureHoverMonitor(for window: NSWindow?) {
        removeHoverMonitor()
        guard let window else { return }
        let titleBarView = window.standardWindowButton(.closeButton)?.superview ?? window.contentView?.superview
        guard let titleBarView else { return }
        window.acceptsMouseMovedEvents = true
        let tracker = TitleBarHoverTracker(window: window, view: titleBarView) { hovering in
            handleTitleBarHover(hovering)
        }
        tracker.install()
        titleBarTracker = tracker
    }

    func handleTitleBarHover(_ hovering: Bool) {
        if isTitleBarHovered != hovering {
            withAnimation(.none) {
                isTitleBarHovered = hovering
            }
        }
    }

    func removeHoverMonitor() {
        titleBarTracker?.uninstall()
        titleBarTracker = nil
        withAnimation(.none) {
            isTitleBarHovered = false
        }
    }
}

private extension BlockEditorView {
    func createTagFromSheet() {
        let color = TagColor(color: newTagColor)
        Task {
            let result = await actions.createTag(newTagName, color)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                switch result {
                case .success(let tag):
                    Task { _ = await actions.setTag(liveBlock.id, tag.id) }
                    isTagCreationPresented = false
                    tagCreationError = nil
                case .failure(let error):
                    tagCreationError = (error as? LocalizedError)?.errorDescription ?? "Unable to save tag."
                }
            }
        }
    }
}

private extension BlockEditorView {
    func buildMarkdown() -> String {
        document?.serialize() ?? ""
    }

    func loadBacklinks() async {
        let title = liveBlock.displayTitle
        guard title != "Untitled" else {
            backlinks = []
            return
        }
        let entries = await IndexCoordinator.shared.findBacklinks(for: title)
        guard !Task.isCancelled else { return }
        let currentBlockId = block.id
        let blockTypeById: [String: BlockType] = Dictionary(
            actions.blocksSnapshot().map { ($0.id, $0.metadata.type) },
            uniquingKeysWith: { _, new in new }
        )
        let items = entries
            .filter { $0.id != currentBlockId }
            .map { entry -> BacklinkItem in
                let type = blockTypeById[entry.id] ?? MarkdownConverter.shared.type(in: entry.content)
                return BacklinkItem(
                    id: entry.id,
                    title: entry.title,
                    contextSnippet: BacklinksPanel.extractContext(from: entry.content, for: title),
                    type: type
                )
            }
        await MainActor.run {
            backlinks = items
        }
    }

    func refreshBacklinks() {
        backlinksTask?.cancel()
        backlinksTask = Task {
            await loadBacklinks()
        }
    }

    func scheduleBacklinksRefresh() {
        backlinksRefreshTask?.cancel()
        backlinksRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            refreshBacklinks()
        }
    }

    func refreshSuggestionCaches() {
        let blocks = actions.blocksSnapshot()
        let newWiki = blocks.map { WikiLinkSuggestionItem(id: $0.id, title: $0.displayTitle) }
        let newMentions = blocks.map { BlockMentionItem(id: $0.id, title: $0.displayTitle) }
        if newWiki != wikiLinkSuggestions {
            wikiLinkSuggestions = newWiki
        }
        if newMentions != mentionableBlocks {
            mentionableBlocks = newMentions
        }
    }

    func scheduleStatusBarRecompute(immediate: Bool) {
        statusBarRecomputeTask?.cancel()
        let markdown = liveBlock.markdown
        statusBarRecomputeTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            let stats = EditorStatusBar.compute(markdown: markdown)
            if Task.isCancelled { return }
            await MainActor.run {
                if statusBarWords != stats.words { statusBarWords = stats.words }
                if statusBarMinutes != stats.minutes { statusBarMinutes = stats.minutes }
            }
        }
    }
}
