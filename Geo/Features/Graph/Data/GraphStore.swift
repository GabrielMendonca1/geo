import Foundation
import SwiftUI
import Combine

@MainActor
final class GraphStore: ObservableObject {
    static let shared = GraphStore()

    @Published private(set) var graph: BlockGraph = .empty
    @Published private(set) var idLookup: [UUID: String] = [:]

    private(set) var cachedPositions: [UUID: CGPoint] = [:]
    private(set) var simulationSettled: Bool = false

    private var lastFingerprint: [String: Int] = [:]
    private var observationTask: Task<Void, Never>?

    private init() {}

    func startObserving(_ blocksViewModel: BlocksViewModel) {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            let stream = blocksViewModel.$blocks
                .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
                .values
            for await blocks in stream {
                await self?.refresh(from: blocks)
            }
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
            let blockById = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
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
    }
}
