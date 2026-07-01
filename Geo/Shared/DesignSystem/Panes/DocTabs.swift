import SwiftUI
import AppKit

// MARK: - Reusable tabbed file-editor (shared by Brains and Nodes)
//
// Center column only: a PaneTabBar of open documents + the live block editor for the active one.
// Sidebar and graph stay per-feature. Everything feature-specific (how a doc is resolved, backlinks,
// wikilink targets, pop-out, new-doc) is INJECTED — this file knows nothing about brains or blocks.

struct OpenDocRef: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
}

@MainActor
final class DocTabsModel: ObservableObject {
    @Published private(set) var openRefs: [OpenDocRef] = []
    @Published var activeId: String?
    /// Which tabs are currently mounted (active + most-recent, capped). Cold tabs are not in the view tree.
    @Published private(set) var liveIds: Set<String> = []

    private var refById: [String: OpenDocRef] = [:]            // g-triad #1: O(1) lookup, never array.first in a loop
    private var editors: [String: ExternalFileEditorModel] = [:]
    private var lru: [String] = []                             // most-recent-last
    private let maxLive: Int

    init(maxLive: Int = 4) { self.maxLive = maxLive }

    var activeRef: OpenDocRef? { activeId.flatMap { refById[$0] } }
    func ref(_ id: String) -> OpenDocRef? { refById[id] }

    func open(_ ref: OpenDocRef) {
        refById[ref.id] = ref
        if !openRefs.contains(where: { $0.id == ref.id }) { openRefs.append(ref) }
        activate(ref.id)
    }

    func activate(_ id: String) {
        guard refById[id] != nil else { return }
        activeId = id
        ensureLive(id)
    }

    func move(from: Int, to: Int) {
        guard openRefs.indices.contains(from), openRefs.indices.contains(to), from != to else { return }
        let ref = openRefs.remove(at: from)
        openRefs.insert(ref, at: to)
    }

    // The live editor for a ref — created when the tab becomes live (in ensureLive), returned here.
    func editor(for ref: OpenDocRef) -> ExternalFileEditorModel {
        if let existing = editors[ref.id] { return existing }
        let model = ExternalFileEditorModel(url: ref.url)
        editors[ref.id] = model
        return model
    }

    func close(_ id: String) {
        evict(id)
        lru.removeAll { $0 == id }
        guard let idx = openRefs.firstIndex(where: { $0.id == id }) else { return }
        openRefs.remove(at: idx)
        refById[id] = nil
        if activeId == id {
            let next = openRefs.indices.contains(idx) ? openRefs[idx].id : openRefs.last?.id
            activeId = next
            if let next { ensureLive(next) }
        }
        liveIds = Set(lru)
    }

    func closeAll() {
        for id in Array(editors.keys) { evict(id) }
        editors.removeAll(); lru.removeAll(); openRefs.removeAll(); refById.removeAll()
        activeId = nil; liveIds = []
    }

    func flushAll() { for editor in editors.values { editor.flush() } }

    /// Re-resolve open tabs against the owner's current docs: drops vanished docs, refreshes titles.
    func resync(_ resolve: (String) -> OpenDocRef?) {
        var kept: [OpenDocRef] = []
        for ref in openRefs {
            if let fresh = resolve(ref.id) {
                refById[ref.id] = fresh
                kept.append(fresh)
            } else {
                evict(ref.id); lru.removeAll { $0 == ref.id }; refById[ref.id] = nil
            }
        }
        openRefs = kept
        if let active = activeId, refById[active] == nil {
            activeId = kept.last?.id
            if let next = activeId { ensureLive(next) }
        }
        liveIds = Set(lru)
    }

    // g-triad #4: keep only `maxLive` editors mounted; the active tab is never evicted.
    private func ensureLive(_ id: String) {
        if editors[id] == nil, let ref = refById[id] {
            editors[id] = ExternalFileEditorModel(url: ref.url)
        }
        lru.removeAll { $0 == id }
        lru.append(id)
        while lru.count > maxLive {
            guard let victim = lru.first(where: { $0 != activeId }) else { break }
            lru.removeAll { $0 == victim }
            evict(victim)
        }
        liveIds = Set(lru)
    }

    private func evict(_ id: String) {
        if let editor = editors[id] { editor.flush(); editor.stopWatching() }
        editors[id] = nil
    }
}

struct DocTabsView: View {
    @ObservedObject var model: DocTabsModel
    var onWikiLink: (String) -> Void
    var onNew: (() -> Void)? = nil
    var onPopOut: ((OpenDocRef) -> Void)? = nil
    var backlinks: (OpenDocRef) async -> Int = { _ in 0 }
    var emptyState: AnyView = AnyView(EmptyView())
    // Feature-specific controls dropped into the editor's bottom status bar (e.g. type/layer/status
    // chips for Nodes). DocTabs stays generic — the owner injects what the active doc affords.
    var statusAccessory: ((OpenDocRef) -> AnyView)? = nil
    // Per-doc editor content width (full-width toggle resolves to .infinity). Re-evaluated each render
    // so it reacts to the owner's metadata changes.
    var contentMaxWidth: ((OpenDocRef) -> CGFloat)? = nil

    var body: some View {
        VStack(spacing: 0) {
            PaneTabBar(
                tabs: model.openRefs.map { PaneTab(id: $0.id, title: $0.title, icon: "doc.text") },
                activeId: model.activeId,
                onSelect: { model.activate($0) },
                onClose: { model.close($0) },
                onAdd: onNew,
                onReorder: { from, to in model.move(from: from, to: to) }
            )
            Rectangle().fill(Palette.border).frame(height: 1)
            if model.openRefs.isEmpty {
                emptyState
            } else {
                ZStack {
                    ForEach(model.openRefs) { ref in
                        if model.liveIds.contains(ref.id) {
                            DocEditorPane(
                                ref: ref,
                                model: model.editor(for: ref),
                                onWikiLink: onWikiLink,
                                onPopOut: onPopOut,
                                backlinks: backlinks,
                                statusAccessory: statusAccessory,
                                contentMaxWidth: contentMaxWidth?(ref) ?? 720
                            )
                            .opacity(ref.id == model.activeId ? 1 : 0)
                            .allowsHitTesting(ref.id == model.activeId)
                            .zIndex(ref.id == model.activeId ? 1 : 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
    }
}

private struct DocEditorPane: View {
    let ref: OpenDocRef
    @ObservedObject var model: ExternalFileEditorModel
    let onWikiLink: (String) -> Void
    let onPopOut: ((OpenDocRef) -> Void)?
    let backlinks: (OpenDocRef) async -> Int
    var statusAccessory: ((OpenDocRef) -> AnyView)? = nil
    var contentMaxWidth: CGFloat = 720

    @State private var words = 0
    @State private var backlinkCount = 0
    @State private var statusTask: Task<Void, Never>?
    @State private var isOutlinePresented = false

    var body: some View {
        VStack(spacing: 0) {
            if let document = model.document {
                BlockListView(
                    document: document,
                    verticalPadding: 16,   // tighter top than the windowed editor (default 48)
                    contentMaxWidth: contentMaxWidth,
                    contentBaseURL: ref.url.deletingLastPathComponent(),
                    onWikiLinkClicked: { onWikiLink($0.target) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                statusBar
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.load(); scheduleStatus() }
        // g-triad #2: recompute debounced off-render — never serialize()/compute inside body.
        .onChange(of: model.document?.editGeneration ?? 0) { _, _ in scheduleStatus() }
        .onDisappear { statusTask?.cancel() }
    }

    private var outlineButton: some View {
        Button { isOutlinePresented.toggle() } label: {
            Image(systemName: "list.bullet.indent").font(.system(size: 12))
        }
        .buttonStyle(.plain).help("Outline")
        .popover(isPresented: $isOutlinePresented, arrowEdge: .bottom) {
            OutlinePopover(headings: OutlineExtractor.headings(from: model.document?.blocks ?? [])) { blockId in
                model.document?.focusRequest = BlockFocusRequest(blockId: blockId, cursorOffset: 0)
                isOutlinePresented = false
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let onPopOut {
                Button { onPopOut(ref) } label: {
                    Image(systemName: "macwindow.badge.plus").font(.system(size: 12))
                }
                .buttonStyle(.plain).help("Open in a separate window")
            }
            outlineButton
            if let statusAccessory {
                statusAccessory(ref)
            }
            Spacer()
            Label("\(backlinkCount) backlink\(backlinkCount == 1 ? "" : "s")", systemImage: "link")
                .labelStyle(.titleAndIcon)
            Text("·")
            Text("\(words) word\(words == 1 ? "" : "s")")
        }
        .font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }

    private func scheduleStatus() {
        statusTask?.cancel()
        statusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            guard let document = model.document else { return }
            words = EditorStatusBar.compute(markdown: document.serialize()).words
            backlinkCount = await backlinks(ref)
        }
    }
}
