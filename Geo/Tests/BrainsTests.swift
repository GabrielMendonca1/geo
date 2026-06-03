import XCTest
@testable import Geo

final class BrainsTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("brains-\(UUID().uuidString)")
    }

    func testCosineIdenticalIsOne() {
        let v: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(VectorMath.cosineSimilarity(v, v), 1.0, accuracy: 1e-5)
    }

    func testCosineOrthogonalIsZero() {
        XCTAssertEqual(VectorMath.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 1e-6)
    }

    func testCosineOppositeIsNegativeOne() {
        XCTAssertEqual(VectorMath.cosineSimilarity([1, 2], [-1, -2]), -1.0, accuracy: 1e-5)
    }

    func testCosineMismatchedOrEmptyIsZero() {
        XCTAssertEqual(VectorMath.cosineSimilarity([1, 2, 3], [1, 2]), 0)
        XCTAssertEqual(VectorMath.cosineSimilarity([], []), 0)
    }

    func testTopKRanksByDescendingSimilarity() {
        let query: [Float] = [1, 0]
        let candidates: [(id: String, vector: [Float])] = [
            ("a", [1, 0]),
            ("b", [0, 1]),
            ("c", [0.7, 0.7]),
        ]
        let top = VectorMath.topK(query: query, candidates: candidates, k: 2)
        XCTAssertEqual(top.map(\.id), ["a", "c"])
    }

    func testManifestRoundTrips() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("brain.json")
        let manifest = BrainManifest(
            id: "tax-2025",
            title: "Tax 2025",
            gist: "US federal tax",
            kind: .domain,
            sourceCount: 3,
            nodeCount: 9,
            ingestState: .ready,
            embeddingModel: "NLEmbedding",
            embeddingDims: 512,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000)
        )
        try manifest.save(to: url)
        XCTAssertEqual(try BrainManifest.load(from: url), manifest)
    }

    func testRegistryHasPersonalDefault() {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let registry = BrainRegistry(baseURL: base)
        XCTAssertNotNil(registry.manifest(BrainRegistry.personalId))
        XCTAssertTrue(registry.isPersonal(BrainRegistry.personalId))
        XCTAssertEqual(registry.manifest(BrainRegistry.personalId)?.kind, .essence)
    }

    func testRegistryDiscoversDomainBrainsAndSortsEssenceFirst() throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let brainDir = base.appendingPathComponent("Brains/immunology")
        try FileManager.default.createDirectory(at: brainDir, withIntermediateDirectories: true)
        try BrainManifest(id: "immunology", title: "Immunology", kind: .domain)
            .save(to: brainDir.appendingPathComponent("brain.json"))
        let registry = BrainRegistry(baseURL: base)
        XCTAssertEqual(registry.manifest("immunology")?.title, "Immunology")
        XCTAssertTrue(registry.list().contains { $0.id == "immunology" })
        XCTAssertEqual(registry.list().first?.id, BrainRegistry.personalId)
    }

    func testRegistryPathsForDomainBrain() throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let brainDir = base.appendingPathComponent("Brains/x")
        try FileManager.default.createDirectory(at: brainDir, withIntermediateDirectories: true)
        try BrainManifest(id: "x", title: "X", kind: .domain).save(to: brainDir.appendingPathComponent("brain.json"))
        let registry = BrainRegistry(baseURL: base)
        let paths = registry.paths("x")
        XCTAssertEqual(paths?.indexURL.lastPathComponent, "index.sqlite")
        XCTAssertEqual(paths?.blocksDir.lastPathComponent, "Blocks")
        XCTAssertTrue(paths?.folder.path.hasSuffix("Brains/x") ?? false)
    }

    func testRegistryUnknownBrainReturnsNil() {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = BrainRegistry(baseURL: base)
        XCTAssertNil(registry.manifest("nope"))
        XCTAssertNil(registry.paths("nope"))
        XCTAssertNil(registry.index(for: "nope"))
    }

    func testDatabaseBrainIndexLexicalGetAndType() async throws {
        let dbURL = tempDir().appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let database = DatabaseService(databaseURL: dbURL)
        let entry = BlockIndexEntry(
            id: "note-1.md",
            path: "note-1.md",
            title: "Photosynthesis",
            content: "Chloroplasts convert light into sugar",
            createdAt: Date(),
            modifiedAt: Date(),
            tagId: nil,
            dayId: nil,
            openTaskCount: 0,
            completedTaskCount: 0,
            tags: [],
            type: "literature"
        )
        try await database.upsertBlock(entry)
        let index: BrainIndex = DatabaseBrainIndex(id: "test", database: database)

        let fetched = try await index.get(blockId: "note-1.md")
        XCTAssertEqual(fetched?.title, "Photosynthesis")

        let hits = try await index.lexicalSearch("chloroplasts", limit: 10)
        XCTAssertEqual(hits.first?.id, "note-1.md")

        let literature = try await index.listByType("literature")
        XCTAssertEqual(literature.count, 1)

        let semantic = try await index.semanticSearch(query: [0.1, 0.2], k: 5)
        XCTAssertTrue(semantic.isEmpty)
    }

    func testPersonalSchemaHasNoDomainTablesButStaysTolerant() async throws {
        let url = tempDir().appendingPathComponent("personal.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = DatabaseService(databaseURL: url)
        try await database.upsertBlock(BlockIndexEntry(id: "p.md", path: "p.md", title: "P", content: "x", createdAt: Date(), modifiedAt: Date(), tagId: nil, dayId: nil, openTaskCount: 0, completedTaskCount: 0, tags: []))
        let fetched = try await database.fetchBlocks(ids: ["p.md"]).count
        XCTAssertEqual(fetched, 1)
        let vectors = try await database.loadAllVectors()
        XCTAssertTrue(vectors.isEmpty)
        let edges = try await database.outgoingEdges(from: "p.md")
        XCTAssertTrue(edges.isEmpty)
    }

    func testEdgeRoundTripBothDirections() async throws {
        let url = tempDir().appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = DatabaseService(databaseURL: url, schema: .domain)
        try await database.setEdges(forSource: "n1.md", edges: [
            DatabaseService.BrainEdge(sourceId: "n1.md", targetTitle: "Concept A", targetId: "a.md"),
            DatabaseService.BrainEdge(sourceId: "n1.md", targetTitle: "Concept B", targetId: nil),
        ])
        let outgoing = try await database.outgoingEdges(from: "n1.md")
        XCTAssertEqual(outgoing.count, 2)
        let incoming = try await database.incomingEdges(to: "a.md")
        XCTAssertEqual(incoming.count, 1)
        XCTAssertEqual(incoming.first?.sourceId, "n1.md")
    }

    func testResolveEdgeTargetsAndSetEdgesReplaces() async throws {
        let url = tempDir().appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = DatabaseService(databaseURL: url, schema: .domain)
        try await database.setEdges(forSource: "n1.md", edges: [
            DatabaseService.BrainEdge(sourceId: "n1.md", targetTitle: "Concept A", targetId: nil),
        ])
        try await database.resolveEdgeTargets(title: "Concept A", toBlockId: "a.md")
        XCTAssertEqual(try await database.incomingEdges(to: "a.md").count, 1)
        try await database.setEdges(forSource: "n1.md", edges: [
            DatabaseService.BrainEdge(sourceId: "n1.md", targetTitle: "Concept C", targetId: "c.md"),
        ])
        XCTAssertEqual(try await database.outgoingEdges(from: "n1.md").count, 1)
        XCTAssertEqual(try await database.incomingEdges(to: "a.md").count, 0)
    }

    func testVectorBlobRoundTrip() async throws {
        let url = tempDir().appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = DatabaseService(databaseURL: url, schema: .domain)
        try await database.upsertVector(blockId: "b.md", embedding: [0.1, 0.2, 0.3])
        let loaded = try await database.loadAllVectors()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "b.md")
        let roundTripped = loaded.first?.vector ?? []
        XCTAssertEqual(roundTripped.count, 3)
        for (lhs, rhs) in zip(roundTripped, [Float(0.1), 0.2, 0.3]) {
            XCTAssertEqual(lhs, rhs, accuracy: 1e-6)
        }
        try await database.upsertVector(blockId: "b.md", embedding: [0.4, 0.5, 0.6])
        XCTAssertEqual(try await database.loadAllVectors().count, 1)
    }

    func testSemanticSearchRanksByCosineEndToEnd() async throws {
        let url = tempDir().appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = DatabaseService(databaseURL: url, schema: .domain)
        try await database.upsertVector(blockId: "a.md", embedding: [1, 0])
        try await database.upsertVector(blockId: "b.md", embedding: [0, 1])
        try await database.upsertVector(blockId: "c.md", embedding: [0.7, 0.7])
        let index = DatabaseBrainIndex(id: "test", database: database)
        let top = try await index.semanticSearch(query: [1, 0], k: 2)
        XCTAssertEqual(top.map(\.id), ["a.md", "c.md"])
    }

    func testSemanticSearchEmptyWhenNoVectors() async throws {
        let url = tempDir().appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = DatabaseService(databaseURL: url, schema: .domain)
        let index = DatabaseBrainIndex(id: "test", database: database)
        XCTAssertTrue(try await index.semanticSearch(query: [1, 0], k: 5).isEmpty)
    }
}
