import XCTest
@testable import Geo

final class BrainGraphStoreTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("braingraph-\(UUID().uuidString)")
    }

    private func makeBrain(base: URL, id: String) throws -> BrainRegistry {
        let dir = base.appendingPathComponent("Brains/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try BrainManifest(id: id, title: id.uppercased(), kind: .domain).save(to: dir.appendingPathComponent("brain.json"))
        return BrainRegistry(baseURL: base)
    }

    func testActiveGateSemanticsMatchTabFallback() {
        func gate(_ isActive: (() -> Bool)?, _ tabIsNodes: Bool) -> Bool { isActive?() ?? tabIsNodes }
        XCTAssertTrue(gate(nil, true))
        XCTAssertFalse(gate(nil, false))
        XCTAssertTrue(gate({ true }, false))
        XCTAssertFalse(gate({ false }, true))
    }

    @MainActor
    func testBrainGraphStoreLoadsSeededDomainGraph() async throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = try makeBrain(base: base, id: "g")
        let database = try XCTUnwrap(registry.database(for: "g"))
        let now = Date()
        try await database.upsertBlock(BlockIndexEntry(id: "a.md", path: "a.md", title: "Alpha", content: "# Alpha\n\nLinks to [[Beta]]", createdAt: now, modifiedAt: now, tagId: nil, dayId: nil, openTaskCount: 0, completedTaskCount: 0, tags: [], type: "literature", status: nil, layer: "shared"))
        try await database.upsertBlock(BlockIndexEntry(id: "b.md", path: "b.md", title: "Beta", content: "# Beta\n\nLeaf node.", createdAt: now, modifiedAt: now, tagId: nil, dayId: nil, openTaskCount: 0, completedTaskCount: 0, tags: [], type: "literature", status: nil, layer: "shared"))

        let store = BrainGraphStore()
        await store.load(brainId: "g", registry: registry)
        XCTAssertEqual(store.graph.nodes.count, 2)
    }

    @MainActor
    func testBrainGraphStoreEmptyBrainIsEmpty() async throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = try makeBrain(base: base, id: "e")
        let store = BrainGraphStore()
        await store.load(brainId: "e", registry: registry)
        XCTAssertEqual(store.graph.nodes.count, 0)
    }
}
