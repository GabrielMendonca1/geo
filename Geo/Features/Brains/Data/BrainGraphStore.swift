import SwiftUI

@MainActor
final class BrainGraphStore: ObservableObject {
    @Published private(set) var graph: BlockGraph = .empty
    @Published private(set) var idLookup: [UUID: String] = [:]
    private(set) var cachedPositions: [UUID: CGPoint] = [:]
    private(set) var simulationSettled: Bool = false

    func load(brainId: String, registry: BrainRegistry = .shared) async {
        guard let database = registry.database(for: brainId) else { return }
        let service = BlockGraphService(
            indexCoordinator: IndexCoordinator(database: database),
            tagStore: TagStore.shared
        )
        guard let result = try? await service.loadGraph() else { return }
        graph = result.graph
        idLookup = result.idLookup
    }

    func updateLayoutCache(positions: [UUID: CGPoint], settled: Bool) {
        cachedPositions = positions
        simulationSettled = settled
    }
}
