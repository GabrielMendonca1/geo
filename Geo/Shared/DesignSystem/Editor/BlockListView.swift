import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BlockListView: View {
    var document: BlockEditorDocument
    var fontSize: CGFloat = GeoStyle.Typography.editorFontSize
    var horizontalPadding: CGFloat = GeoStyle.Spacing.editorPaddingHorizontal
    var verticalPadding: CGFloat = GeoStyle.Spacing.editorPaddingVertical
    var contentMaxWidth: CGFloat = 720
    var contentBaseURL: URL?
    var accentColor: Color?
    var attachmentHandler: ((NSPasteboard, NSTextView) -> Bool)?
    var mentionableBlocks: [BlockMentionItem] = []
    var onWikiLinkClicked: ((WikiLinkClickPayload) -> Void)?

    @Environment(\.undoManager) private var undoManager
    @State private var focusCoordinator: EditorFocusCoordinator
    @State private var selectionManager: BlockSelectionManager
    @State private var dragController: BlockDragController
    @State private var router: BlockEventRouter
    @State private var isTemplatePickerPresented = false
    @State private var templateInsertionIndex: Int = 0
    @State private var findSearchText = ""
    @State private var findReplaceText = ""
    @State private var findShowReplace = false
    @State private var findMatches: [(blockIndex: Int, range: NSRange)] = []
    @State private var findCurrentMatch: Int = 0
    @State private var findDebounceTask: Task<Void, Never>?
    @State private var cachedVisibleIndices: [Int] = []
    @State private var lastStructuralGen: UInt64 = 0
    @State private var rowBounds: [UUID: CGRect] = [:]

    init(
        document: BlockEditorDocument,
        fontSize: CGFloat = GeoStyle.Typography.editorFontSize,
        horizontalPadding: CGFloat = GeoStyle.Spacing.editorPaddingHorizontal,
        verticalPadding: CGFloat = GeoStyle.Spacing.editorPaddingVertical,
        contentMaxWidth: CGFloat = 720,
        contentBaseURL: URL? = nil,
        accentColor: Color? = nil,
        attachmentHandler: ((NSPasteboard, NSTextView) -> Bool)? = nil,
        mentionableBlocks: [BlockMentionItem] = [],
        onWikiLinkClicked: ((WikiLinkClickPayload) -> Void)? = nil
    ) {
        self.document = document
        self.fontSize = fontSize
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.contentMaxWidth = contentMaxWidth
        self.contentBaseURL = contentBaseURL
        self.accentColor = accentColor
        self.attachmentHandler = attachmentHandler
        self.mentionableBlocks = mentionableBlocks
        self.onWikiLinkClicked = onWikiLinkClicked

        let fc = EditorFocusCoordinator()
        let sm = BlockSelectionManager()
        let dc = BlockDragController()
        _focusCoordinator = State(initialValue: fc)
        _selectionManager = State(initialValue: sm)
        _dragController = State(initialValue: dc)
        _router = State(initialValue: BlockEventRouter(
            document: document,
            focusCoordinator: fc,
            selectionManager: sm,
            mentionableBlocks: mentionableBlocks,
            onWikiLinkClicked: onWikiLinkClicked
        ))
    }

    private var visibleIndices: [Int] {
        if cachedVisibleIndices.isEmpty || lastStructuralGen != document.structuralGeneration {
            return BlockTreeNavigator.visibleBlocks(document.blocks)
        }
        return cachedVisibleIndices
    }

    var body: some View {
        VStack(spacing: 0) {
            if router.isFindPresented {
                FindReplaceBar(
                    searchText: $findSearchText,
                    replaceText: $findReplaceText,
                    showReplace: $findShowReplace,
                    matchCount: findMatches.count,
                    currentMatch: findCurrentMatch,
                    onNext: { findNext() },
                    onPrevious: { findPrevious() },
                    onReplace: { replaceCurrent() },
                    onReplaceAll: { replaceAll() },
                    onDismiss: { router.isFindPresented = false; findSearchText = "" }
                )
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        SlimWhiteScroller().frame(width: 0, height: 0)
                        let highlightsByBlock = Dictionary(grouping: findMatches, by: \.blockIndex).mapValues { $0.map(\.range) }
                        let activeMatch = findCurrentMatch < findMatches.count ? findMatches[findCurrentMatch] : nil
                        let parentIds = Set(document.blocks.compactMap { $0.parentId })
                        ForEach(visibleIndices.map { (index: $0, id: document.blocks[$0].id) }, id: \.id) { pair in
                            let index = pair.index
                            let block = document.blocks[index]
                            let isSlash = router.slashState?.blockId == block.id
                            let isMention = router.mentionState?.blockId == block.id
                            let rowConfig = BlockRowConfiguration(
                                block: block,
                                depth: block.depth,
                                hasChildren: parentIds.contains(block.id),
                                isCollapsed: block.collapsed,
                                isFocused: focusCoordinator.activeFocusedBlockId == block.id && !selectionManager.selectedBlockIds.isEmpty,
                                isSelected: selectionManager.selectedBlockIds.contains(block.id),
                                isDragSource: dragController.draggedSubtreeIds(in: document.blocks).contains(block.id),
                                hasMultiBlockSelection: router.currentSelection.isMultiBlock,
                                fontSize: fontSize,
                                highlightRanges: highlightsByBlock[index] ?? [],
                                activeHighlightRange: {
                                    guard let match = activeMatch else { return nil }
                                    return match.blockIndex == index ? match.range : nil
                                }(),
                                isSlashMode: isSlash,
                                isMentionMode: isMention,
                                contentBaseURL: contentBaseURL,
                                accentColor: accentColor
                            )
                            let rowCallbacks = makeRowCallbacks(index: index, block: block, proxy: proxy)
                            VStack(spacing: 0) {
                                if dragController.dropTargetIndex == index && dragController.draggedBlockId != block.id {
                                    dropIndicator
                                }
                                EquatableBlockRow(
                                    config: rowConfig,
                                    callbacks: rowCallbacks,
                                    focusCoordinator: focusCoordinator,
                                    contextMenuContent: { AnyView(blockContextMenu(for: block)) }
                                )
                                .equatable()
                            }
                            .id(block.id)
                            .onDrop(of: [UTType.text], delegate: dragController.makeDropDelegate(
                                targetIndex: index,
                                moveBlock: { fromId, toIdx in dragController.performDrop(blockId: fromId, toIndex: toIdx, in: document, undoManager: undoManager) }
                            ))
                        }

                        if let dti = dragController.dropTargetIndex, dti >= document.blocks.count {
                            dropIndicator
                        }

                        addBlockArea
                            .onDrop(of: [UTType.text], delegate: dragController.makeDropDelegate(
                                targetIndex: document.blocks.count,
                                moveBlock: { fromId, toIdx in dragController.performDrop(blockId: fromId, toIndex: toIdx, in: document, undoManager: undoManager) }
                            ))
                    }
                    .frame(maxWidth: contentMaxWidth)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .frame(maxWidth: .infinity)
                    .onPreferenceChange(BlockRowBoundsKey.self) { newBounds in
                        if newBounds != rowBounds { rowBounds = newBounds }
                    }
                }
                .coordinateSpace(name: "editor")
                .overlay(alignment: .topLeading) {
                    EditorOverlayLayer(
                        router: router,
                        rowBounds: rowBounds,
                        mentionableBlocks: mentionableBlocks,
                        onSlashSelect: { cmd, idx in
                            router.executeBlockSlashCommand(cmd, at: idx)
                            consumeTemplatePickerRequest(at: idx)
                        },
                        onMentionSelect: { item, idx in
                            router.executeMention(item, at: idx)
                        }
                    )
                }
                .onChange(of: selectionManager.selectedBlockIds) { _, newValue in
                    selectionManager.installSelectionMonitor(
                        active: !newValue.isEmpty,
                        blocks: { [document] in document.blocks },
                        focusCoordinator: focusCoordinator,
                        document: document,
                        undoManager: undoManager
                    )
                }
                .onAppear {
                    cachedVisibleIndices = BlockTreeNavigator.visibleBlocks(document.blocks)
                    lastStructuralGen = document.structuralGeneration
                }
                .onChange(of: document.structuralGeneration) { _, newGen in
                    guard newGen != lastStructuralGen else { return }
                    lastStructuralGen = newGen
                    cachedVisibleIndices = BlockTreeNavigator.visibleBlocks(document.blocks)
                }
                .onDisappear {
                    selectionManager.teardownMonitor()
                }
                .onChange(of: document.focusRequest) { _, newValue in
                    if let req = newValue {
                        DispatchQueue.main.async {
                            proxy.scrollTo(req.blockId, anchor: .center)
                        }
                        focusCoordinator.requestFocus(blockId: req.blockId, cursorOffset: req.cursorOffset)
                    }
                }
            }
            .onChange(of: findSearchText) { _, newValue in
                findDebounceTask?.cancel()
                if newValue.isEmpty {
                    findMatches = []
                    findCurrentMatch = 0
                    return
                }
                findDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    computeFindMatches(query: newValue)
                }
            }
        }
        .sheet(isPresented: $isTemplatePickerPresented) {
            TemplatePickerSheet { template in
                let expanded = TemplateService.shared.expandVariables(in: template.markdown, title: "")
                router.insertTemplateBlocks(markdown: expanded.markdown, at: templateInsertionIndex, cursorOffset: expanded.cursorOffset)
            }
            .environmentObject(TemplateService.shared)
        }
        .onAppear {
            router.undoManager = undoManager
            router.mentionableBlocks = mentionableBlocks
            router.onWikiLinkClicked = onWikiLinkClicked
        }
        .onChange(of: mentionableBlocks) { _, newValue in router.mentionableBlocks = newValue }
    }

    private func consumeTemplatePickerRequest(at index: Int) {
        if router.templatePickerRequested {
            router.templatePickerRequested = false
            templateInsertionIndex = index
            isTemplatePickerPresented = true
        }
    }

    private func makeRowCallbacks(index: Int, block: EditorBlock, proxy: ScrollViewProxy) -> BlockRowCallbacks {
        let blockId = block.id
        return BlockRowCallbacks(
            attachmentHandler: attachmentHandler,
            onEvent: { event in
                router.handleEvent(event, on: blockId)
                let resolved = document.index(of: blockId) ?? index
                consumeTemplatePickerRequest(at: resolved)
            },
            onDragOutside: { windowPoint in
                let resolved = document.index(of: blockId) ?? index
                selectionManager.handleDragOutside(windowPoint, fromIndex: resolved, in: document.blocks, focusCoordinator: focusCoordinator)
            },
            onToggleCheckbox: { router.toggleCheckbox(id: blockId) },
            onHandleClick: {
                let resolved = document.index(of: blockId) ?? index
                selectionManager.handleBlockHandleClick(at: resolved, blockId: blockId, in: document.blocks, focusCoordinator: focusCoordinator)
            },
            onDragStart: { dragController.draggedBlockId = blockId },
            onToggleCollapse: { router.toggleCollapse(id: blockId) }
        )
    }

    @ViewBuilder
    private func blockContextMenu(for block: EditorBlock) -> some View {
        if selectionManager.selectedBlockIds.count > 1 {
            Button("Delete \(selectionManager.selectedBlockIds.count) Blocks") { selectionManager.deleteSelectedBlocks(from: document, undoManager: undoManager) }
            Button("Duplicate \(selectionManager.selectedBlockIds.count) Blocks") { selectionManager.duplicateSelectedBlocks(in: document, undoManager: undoManager) }
            Divider()
            Button("Clear Selection") { selectionManager.clearSelection() }
        } else {
            let blockId = block.id
            let index = document.index(of: blockId) ?? 0
            Menu("Turn Into") {
                Button("Paragraph") { router.convertBlock(id: blockId, to: .paragraph) }
                Divider()
                Button("Heading 1") { router.convertBlock(id: blockId, to: .heading(level: 1)) }
                Button("Heading 2") { router.convertBlock(id: blockId, to: .heading(level: 2)) }
                Button("Heading 3") { router.convertBlock(id: blockId, to: .heading(level: 3)) }
                Divider()
                Button("Bullet List") { router.convertBlock(id: blockId, to: .bulletItem(marker: "-")) }
                Button("Numbered List") { router.convertBlock(id: blockId, to: .orderedItem(number: 1)) }
                Button("To-do") { router.convertBlock(id: blockId, to: .checkboxItem(checked: false, marker: "-")) }
                Divider()
                Button("Quote") { router.convertBlock(id: blockId, to: .blockquote) }
                Button("Toggle") { router.convertBlock(id: blockId, to: .toggle(expanded: true)) }
                Button("Math Block") { router.convertBlock(id: blockId, to: .mathBlock) }
                Divider()
                Menu("Callout") {
                    ForEach(CalloutType.allCases, id: \.self) { type in
                        Button(type.displayName) { router.convertBlock(id: blockId, to: .callout(type: type, title: nil)) }
                    }
                }
            }
            Divider()
            Button("Duplicate") { router.duplicateBlock(id: blockId) }
            Button("Delete") { router.deleteBlock(id: blockId) }
            Divider()
            Button("Move Up") { router.moveBlockUp(id: blockId) }
                .disabled(index == 0)
            Button("Move Down") { router.moveBlockDown(id: blockId) }
                .disabled(index >= document.blocks.count - 1)
            Divider()
            Button("Insert Above") { router.insertBlock(beforeId: blockId) }
            Button("Insert Below") { router.insertBlock(afterId: blockId) }
        }
    }

    private var addBlockArea: some View {
        Color.clear
            .frame(height: 200)
            .contentShape(Rectangle())
            .onTapGesture {
                selectionManager.clearSelection()
                focusCoordinator.clearActiveFocus()
                NSApp.keyWindow?.makeFirstResponder(nil)
                router.appendBlock()
            }
    }

    private var dropIndicator: some View {
        Rectangle()
            .fill(Palette.accent)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .padding(.leading, 16)
            .transition(.opacity)
    }

    private func computeFindMatches(query: String) {
        guard !query.isEmpty else {
            findMatches = []
            findCurrentMatch = 0
            return
        }
        var matches: [(blockIndex: Int, range: NSRange)] = []
        for (index, block) in document.blocks.enumerated() {
            let content = block.content as NSString
            var searchRange = NSRange(location: 0, length: content.length)
            while searchRange.location < content.length {
                let range = content.range(of: query, options: [.caseInsensitive], range: searchRange)
                guard range.location != NSNotFound else { break }
                matches.append((blockIndex: index, range: range))
                searchRange.location = NSMaxRange(range)
                searchRange.length = content.length - searchRange.location
            }
        }
        findMatches = matches
        findCurrentMatch = matches.isEmpty ? 0 : min(findCurrentMatch, matches.count - 1)
    }

    private func findNext() {
        guard !findMatches.isEmpty else { return }
        findCurrentMatch = (findCurrentMatch + 1) % findMatches.count
        scrollToCurrentMatch()
    }

    private func findPrevious() {
        guard !findMatches.isEmpty else { return }
        findCurrentMatch = (findCurrentMatch - 1 + findMatches.count) % findMatches.count
        scrollToCurrentMatch()
    }

    private func scrollToCurrentMatch() {
        guard findCurrentMatch < findMatches.count else { return }
        let match = findMatches[findCurrentMatch]
        guard match.blockIndex < document.blocks.count else { return }
        let blockId = document.blocks[match.blockIndex].id
        document.focusRequest = BlockFocusRequest(blockId: blockId, cursorOffset: match.range.location)
    }

    private func replaceCurrent() {
        guard findCurrentMatch < findMatches.count else { return }
        let match = findMatches[findCurrentMatch]
        guard match.blockIndex < document.blocks.count else { return }
        let block = document.blocks[match.blockIndex]
        let content = block.content as NSString
        let newContent = content.replacingCharacters(in: match.range, with: findReplaceText)
        document.performStructuralEdit(undoManager: undoManager, name: "Replace", newFocus: nil) { blocks in
            guard match.blockIndex < blocks.count else { return }
            blocks[match.blockIndex] = blocks[match.blockIndex].withContent(newContent, spans: [])
        }
        computeFindMatches(query: findSearchText)
    }

    private func replaceAll() {
        guard !findMatches.isEmpty else { return }
        document.performStructuralEdit(undoManager: undoManager, name: "Replace All", newFocus: nil) { blocks in
            for match in findMatches.reversed() {
                guard match.blockIndex < blocks.count else { continue }
                let content = blocks[match.blockIndex].content as NSString
                let newContent = content.replacingCharacters(in: match.range, with: findReplaceText)
                blocks[match.blockIndex] = blocks[match.blockIndex].withContent(newContent, spans: [])
            }
        }
        computeFindMatches(query: findSearchText)
    }
}

// Slim, white scroll knob for the editor. Configures the enclosing NSScrollView INSTANCE (overlay
// style + light knob) — deliberately NOT a global NSScroller method swizzle, which froze the text
// system app-wide. Instance appearance config never touches text-view events.
private struct SlimWhiteScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { StylerView() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? StylerView)?.applyStyle() }

    final class StylerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyStyle()
        }

        func applyStyle() {
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView else { return }
                scrollView.scrollerStyle = .overlay
                scrollView.verticalScroller?.knobStyle = .light
                scrollView.horizontalScroller?.knobStyle = .light
            }
        }
    }
}
