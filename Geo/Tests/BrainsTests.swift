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

    func testMCPRegistryDispatchesTool() async throws {
        let echo = MCPToolBuilder(name: "search_blocks", description: "", schema: JSONSchemaObject(properties: [:]), handler: { _ in .text("ran") }).registered
        let registry = MCPToolRegistry(tools: [echo])
        let result = try await registry.call(name: "search_blocks", arguments: [:])
        XCTAssertEqual(result.content.first?.text, "ran")
        XCTAssertNil(result.isError)
    }

    func testMCPRegistryUnknownToolErrors() async throws {
        let registry = MCPToolRegistry(tools: [])
        let result = try await registry.call(name: "ghost", arguments: [:])
        XCTAssertEqual(result.isError, true)
    }

    func testBrainToolsListAndManifest() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBrain(root: root, id: "immunology", title: "Immunology", gist: "T cells", nodes: 2, sources: ["a.pdf"])
        let brains = BrainRegistry(root: root)
        let tools = BrainTools.register(registry: brains)

        let list = try XCTUnwrap(tools.first { $0.definition.name == "list_brains" })
        let listResult = try await list.handler([:])
        XCTAssertNil(listResult.isError)
        XCTAssertTrue(listResult.content.first?.text.contains("essence") ?? false)
        XCTAssertTrue(listResult.content.first?.text.contains("immunology") ?? false)

        let manifestTool = try XCTUnwrap(tools.first { $0.definition.name == "get_brain_manifest" })
        let known = try await manifestTool.handler(["brain": .string("immunology")])
        XCTAssertNil(known.isError)
        XCTAssertTrue(known.content.first?.text.contains("\"ready\"") ?? false)
        let unknown = try await manifestTool.handler(["brain": .string("nope")])
        XCTAssertEqual(unknown.isError, true)
    }
}
