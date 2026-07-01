import XCTest
@testable import Geo

final class BrainsTests: XCTestCase {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("brains-\(UUID().uuidString)")
    }

    /// Writes a flat `.brain.json` (the schema brain.py / the in-app vault store actually write)
    /// into `<root>/<id>/.brain.json` and returns the root.
    @discardableResult
    private func seedBrain(root: URL, id: String, title: String, gist: String = "", nodes: Int = 0, sources: [String] = []) throws -> URL {
        let dir = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {
          "id": "\(id)",
          "title": "\(title)",
          "gist": "\(gist)",
          "nodes": \(nodes),
          "sources": [\(sources.map { "\"\($0)\"" }.joined(separator: ", "))]
        }
        """
        try json.write(to: dir.appendingPathComponent(".brain.json"), atomically: true, encoding: .utf8)
        return root
    }

    func testManifestDecodesFlatBrainJSON() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBrain(root: root, id: "immunology", title: "Immunology", gist: "T cells", nodes: 3, sources: ["a.pdf", "b.txt"])
        let manifest = try BrainManifest.load(from: root.appendingPathComponent("immunology/.brain.json"))
        XCTAssertEqual(manifest.id, "immunology")
        XCTAssertEqual(manifest.title, "Immunology")
        XCTAssertEqual(manifest.gist, "T cells")
        XCTAssertEqual(manifest.nodeCount, 3)
        XCTAssertEqual(manifest.sourceCount, 2)
        XCTAssertEqual(manifest.kind, .domain)
        XCTAssertEqual(manifest.state, "ready")
    }

    func testRegistryHasPersonalDefault() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = BrainRegistry(root: root)
        XCTAssertNotNil(registry.manifest(BrainRegistry.personalId))
        XCTAssertTrue(registry.isPersonal(BrainRegistry.personalId))
        XCTAssertEqual(registry.manifest(BrainRegistry.personalId)?.kind, .essence)
        XCTAssertEqual(registry.manifest(BrainRegistry.personalId)?.state, "ready")
    }

    func testRegistryDiscoversDomainBrainsAndSortsEssenceFirst() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBrain(root: root, id: "immunology", title: "Immunology", nodes: 0)
        let registry = BrainRegistry(root: root)
        XCTAssertEqual(registry.manifest("immunology")?.title, "Immunology")
        XCTAssertEqual(registry.manifest("immunology")?.state, "empty")
        XCTAssertTrue(registry.list().contains { $0.id == "immunology" })
        XCTAssertEqual(registry.list().first?.id, BrainRegistry.personalId)
    }

    func testRegistryReloadPicksUpNewVault() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = BrainRegistry(root: root)
        XCTAssertNil(registry.manifest("finance"))
        try seedBrain(root: root, id: "finance", title: "Finance")
        registry.reload()
        XCTAssertEqual(registry.manifest("finance")?.title, "Finance")
    }

    func testRegistryUnknownBrainReturnsNil() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = BrainRegistry(root: root)
        XCTAssertNil(registry.manifest("nope"))
    }

    // MARK: - Graph builder (local subgraph + backlinks)

    private func note(_ id: String, links: [String] = []) -> BrainNote {
        let body = "# \(id)\n\n" + links.map { "[[\($0)]]" }.joined(separator: " ")
        return BrainNote(id: id, title: id, body: body, url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    func testGraphBuildResolvesWikilinks() {
        let notes = [note("a", links: ["b"]), note("b", links: ["c"]), note("c")]
        let built = BrainGraphBuilder.build(notes: notes)
        XCTAssertEqual(built.graph.nodes.count, 3)
        // a->b and b->c are resolved edges
        let resolved = built.graph.edges.filter { $0.targetId != nil }
        XCTAssertEqual(resolved.count, 2)
    }

    func testLocalSubgraphIsOneHopNeighborhood() {
        let notes = [note("a", links: ["b"]), note("b", links: ["c"]), note("c")]
        let graph = BrainGraphBuilder.build(notes: notes).graph
        let center = BrainGraphBuilder.nodeID(forNoteSlug: "a")
        let local = BrainGraphBuilder.localSubgraph(graph, around: center, hops: 1)
        let ids = Set(local.nodes.map(\.id))
        XCTAssertTrue(ids.contains(BrainGraphBuilder.nodeID(forNoteSlug: "a")))
        XCTAssertTrue(ids.contains(BrainGraphBuilder.nodeID(forNoteSlug: "b")))
        XCTAssertFalse(ids.contains(BrainGraphBuilder.nodeID(forNoteSlug: "c")))  // 2 hops away
    }

    func testBacklinkCountCountsIncomingLinks() {
        let notes = [note("a", links: ["c"]), note("b", links: ["c"]), note("c")]
        let graph = BrainGraphBuilder.build(notes: notes).graph
        XCTAssertEqual(BrainGraphBuilder.backlinkCount(graph, to: BrainGraphBuilder.nodeID(forNoteSlug: "c")), 2)
        XCTAssertEqual(BrainGraphBuilder.backlinkCount(graph, to: BrainGraphBuilder.nodeID(forNoteSlug: "a")), 0)
    }

    func testNodeIDIsDeterministic() {
        XCTAssertEqual(BrainGraphBuilder.nodeID(forNoteSlug: "immunology"),
                       BrainGraphBuilder.nodeID(forNoteSlug: "immunology"))
        XCTAssertNotEqual(BrainGraphBuilder.nodeID(forNoteSlug: "a"),
                          BrainGraphBuilder.nodeID(forNoteSlug: "b"))
    }

    // MARK: - Note creation

    @MainActor
    func testCreateNoteWritesUniqueFileWithTitle() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vault = BrainVault(id: "vault", title: "Vault", gist: "", noteCount: 0, sourceCount: 0, folder: folder)
        let store = BrainVaultStore()

        let first = try store.createNote(in: vault, title: "My Idea")
        XCTAssertEqual(first, "my-idea")
        let body = try String(contentsOf: folder.appendingPathComponent("my-idea.md"), encoding: .utf8)
        XCTAssertTrue(body.hasPrefix("# My Idea"))

        // Same title again → a distinct, non-colliding id.
        let second = try store.createNote(in: vault, title: "My Idea")
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(second).md").path))
    }

}
