import Foundation
import SwiftUI
import Combine

struct ExternalChangeSignal: Equatable {
    let nodeIds: Set<UUID>
    let timestamp: Date
}

@MainActor
final class GraphStore: ObservableObject {
    static let shared = GraphStore()

    @Published private(set) var graph: BlockGraph = .empty
    @Published private(set) var idLookup: [UUID: String] = [:]
    @Published private(set) var externalChangeSignal: ExternalChangeSignal?

    private(set) var cachedPositions: [UUID: CGPoint] = [:]
    private(set) var simulationSettled: Bool = false

    private var lastFingerprint: [String: Int] = [:]
    private var observationTask: Task<Void, Never>?
    private var externalChangeObserver: NSObjectProtocol?
    private var pendingExternalStringIds: [(ids: Set<String>, timestamp: Date)] = []
    private let pendingExternalTTL: TimeInterval = 5.0

    deinit {
        if let token = externalChangeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private init() {}

    func startObserving(_ blocksViewModel: BlocksViewModel) {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            let stream = blocksViewModel.$blocks
                .debounce(for: .milliseconds(16), scheduler: DispatchQueue.main)
                .values
            for await blocks in stream {
                await self?.refresh(from: blocks)
            }
        }
        startObservingExternalChanges()
    }

    private func startObservingExternalChanges() {
        guard externalChangeObserver == nil else { return }
        externalChangeObserver = NotificationCenter.default.addObserver(
            forName: .blocksExternallyChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let changed = note.userInfo?[BlockExternalChangeKey.changedIds] as? [String] ?? []
            let removed = note.userInfo?[BlockExternalChangeKey.removedIds] as? [String] ?? []
            let allIds = Set(changed + removed)
            guard !allIds.isEmpty else { return }
            Task { @MainActor in
                self.pendingExternalStringIds.append((allIds, Date()))
                self.resolvePendingExternalIds()
            }
        }
    }

    private func resolvePendingExternalIds() {
        guard !pendingExternalStringIds.isEmpty else { return }
        let now = Date()
        var inverse: [String: UUID] = [:]
        inverse.reserveCapacity(idLookup.count)
        for (uuid, stringId) in idLookup { inverse[stringId] = uuid }

        var resolvedUUIDs = Set<UUID>()
        var latestTimestamp: Date = .distantPast
        var stillPending: [(ids: Set<String>, timestamp: Date)] = []

        for entry in pendingExternalStringIds {
            guard now.timeIntervalSince(entry.timestamp) < pendingExternalTTL else { continue }
            var unresolved = Set<String>()
            for id in entry.ids {
                if let uuid = inverse[id] {
                    resolvedUUIDs.insert(uuid)
                    if entry.timestamp > latestTimestamp { latestTimestamp = entry.timestamp }
                } else {
                    unresolved.insert(id)
                }
            }
            if !unresolved.isEmpty {
                stillPending.append((unresolved, entry.timestamp))
            }
        }
        pendingExternalStringIds = stillPending
        if !resolvedUUIDs.isEmpty {
            externalChangeSignal = ExternalChangeSignal(nodeIds: resolvedUUIDs, timestamp: latestTimestamp)
        }
    }

    func updateLayoutCache(positions: [UUID: CGPoint], settled: Bool) {
        cachedPositions = positions
        simulationSettled = settled
    }

    private func refresh(from blocks: [BlockEntity]) async {
        let service = BlockGraphService(
            indexCoordinator: .shared,
            tagStore: TagStore.shared
        )

        var newFingerprint: [String: Int] = [:]
        newFingerprint.reserveCapacity(blocks.count)
        for block in blocks {
            var hasher = Hasher()
            hasher.combine(block.title)
            hasher.combine(block.markdown)
            hasher.combine(block.tagId)
            hasher.combine(block.metadata.type)
            hasher.combine(block.metadata.layer)
            newFingerprint[block.id] = hasher.finalize()
        }

        var changedIds: [String] = []
        var removedIds: [String] = []
        for (id, fp) in newFingerprint where lastFingerprint[id] != fp {
            changedIds.append(id)
        }
        for id in lastFingerprint.keys where newFingerprint[id] == nil {
            removedIds.append(id)
        }

        let snapshotEmpty = graph.nodes.isEmpty && idLookup.isEmpty
        let totalChange = changedIds.count + removedIds.count
        let fullRebuildThreshold = max(8, blocks.count / 4)
        let useDelta = !snapshotEmpty && !lastFingerprint.isEmpty && totalChange <= fullRebuildThreshold

        if useDelta {
            let blockById = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            let changedEntries: [BlockIndexEntry] = changedIds.compactMap { id in
                guard let block = blockById[id] else { return nil }
                return BlockIndexEntry(
                    id: block.id,
                    path: block.url.path,
                    title: block.title,
                    content: block.markdown,
                    createdAt: block.date,
                    modifiedAt: block.lastEdited,
                    tagId: block.tagId,
                    dayId: block.metadata.dayId,
                    openTaskCount: 0,
                    completedTaskCount: 0,
                    tags: [],
                    type: block.metadata.type.rawValue,
                    status: block.metadata.status,
                    layer: block.metadata.layer.rawValue,
                    isFullWidth: block.metadata.isFullWidth
                )
            }
            let result = await service.applyDelta(
                previous: (graph, idLookup),
                changedEntries: changedEntries,
                removedBlockIds: removedIds,
                allEntries: { await IndexCoordinator.shared.fetchAllBlocks() }
            )
            graph = result.graph
            idLookup = result.idLookup
            lastFingerprint = newFingerprint
            resolvePendingExternalIds()
            return
        }

        if let result = try? await service.loadGraph() {
            graph = result.graph
            idLookup = result.idLookup
        } else {
            graph = .empty
            idLookup = [:]
        }
        lastFingerprint = newFingerprint
        resolvePendingExternalIds()
    }
}
