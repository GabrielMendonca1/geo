import Foundation

// MARK: - Per-vault data (notes + graph) bridged to the shared DocTabsModel

@MainActor
final class BrainWorkspaceModel: ObservableObject {
    @Published private(set) var notes: [BrainNote] = []

    // Tabs + live editors live in the shared component.
    let tabs = DocTabsModel()

    private(set) var graph: BlockGraph = .empty
    private(set) var lookup: [UUID: BrainNote] = [:]
    private var notesById: [String: BrainNote] = [:]     // g-triad #1: O(1) lookup
    private var graphCache: BrainGraphCache = .empty      // g-triad #3: adjacency + degree built once
    private(set) var vaultId: String?

    var activeNote: BrainNote? { tabs.activeId.flatMap { notesById[$0] } }

    func setVault(_ vault: BrainVault) {
        guard vault.id != vaultId else { return }
        tabs.closeAll()
        vaultId = vault.id
    }

    func loadNotes(_ notes: [BrainNote], graph: BlockGraph, lookup: [UUID: BrainNote]) {
        self.notes = notes
        self.graph = graph
        self.lookup = lookup
        notesById = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        graphCache = BrainGraphCache(graph: graph)
        // Prune tabs whose notes vanished; refresh titles for the rest.
        tabs.resync { id in notesById[id].map { OpenDocRef(id: $0.id, title: $0.title, url: $0.url) } }
    }

    func open(_ noteId: String) {
        guard let note = notesById[noteId] else { return }
        tabs.open(OpenDocRef(id: note.id, title: note.title, url: note.url))
    }

    // [[wikilink]] navigation: resolve link text to a note by slug or title.
    func openByTarget(_ target: String) {
        let slug = BrainVaultStore.slug(target)
        if let note = notesById[slug] ?? notes.first(where: { $0.title.localizedCaseInsensitiveCompare(target) == .orderedSame }) {
            open(note.id)
        }
    }

    func flushAll() { tabs.flushAll() }

    func backlinkCount(for ref: OpenDocRef) -> Int {
        graphCache.backlinkCount(to: BrainGraphBuilder.nodeID(forNoteSlug: ref.id))
    }

    func localSubgraph(around note: BrainNote) -> BlockGraph {
        graphCache.localSubgraph(in: graph, around: BrainGraphBuilder.nodeID(forNoteSlug: note.id), hops: 1)
    }
}
