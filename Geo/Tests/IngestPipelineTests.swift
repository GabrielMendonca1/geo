import XCTest
@testable import Geo

private struct FakeSummarizer: ChunkSummarizer {
    func summarize(_ chunk: String, context: SummarizeContext) async throws -> String {
        "# Note \(Chunker.hash(chunk).prefix(6))\n\nKey idea about [[Mitochondria]] and [[mitochondria]]."
    }
}

private struct FakeEmbedder: EmbeddingService {
    let fixed: [Float] = [1, 0, 0]
    var dims: Int { 3 }
    func embed(_ text: String) async -> [Float]? { fixed }
}

final class IngestPipelineTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ingest-\(UUID().uuidString)")
    }

    private func makeBrain(base: URL, id: String, sourceText: String) throws -> BrainRegistry {
        let dir = base.appendingPathComponent("Brains/\(id)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try sourceText.write(to: dir.appendingPathComponent("sources/doc.txt"), atomically: true, encoding: .utf8)
        try BrainManifest(id: id, title: "Test KB", kind: .domain).save(to: dir.appendingPathComponent("brain.json"))
        return BrainRegistry(baseURL: base)
    }

    func testChunkerOverlapAndCount() {
        let words = (1...900).map { "w\($0)" }.joined(separator: " ")
        let chunks = Chunker.chunk(words, sourceLabel: "s", targetWords: 800, overlapWords: 80)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].order, 0)
        XCTAssertEqual(chunks[1].order, 1)
    }

    func testChunkHashIsNFCStable() {
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        XCTAssertEqual(Chunker.hash(nfc), Chunker.hash(nfd))
    }

    func testReconcileCanonicalDeterministicAndOrderIndependent() {
        let forward = BrainReconciler.canonicalTitles(forMentions: ["Mitochondria", "mitochondria", "MITOCHONDRIA"])
        let shuffled = BrainReconciler.canonicalTitles(forMentions: ["MITOCHONDRIA", "Mitochondria", "mitochondria"])
        XCTAssertEqual(forward, shuffled)
        XCTAssertEqual(forward[WikiTitleNormalizer.normalize("mitochondria")], "MITOCHONDRIA")
    }

    func testReconcileRewritesLinksPreservingAlias() {
        let canonical = BrainReconciler.canonicalTitles(forMentions: ["Mitochondria", "mitochondria"])
        let out = BrainReconciler.rewriteLinks(in: "See [[mitochondria]] and [[mitochondria|the powerhouse]].", canonicalByKey: canonical)
        XCTAssertTrue(out.contains("[[Mitochondria]]"))
        XCTAssertTrue(out.contains("[[Mitochondria|the powerhouse]]"))
        XCTAssertFalse(out.contains("[[mitochondria]]"))
    }

    func testStripHTMLRemovesTagsAndScripts() {
        let html = "<html><head><style>x{color:red}</style></head><body><p>Hello <b>world</b></p><script>bad()</script></body></html>"
        let text = SourceExtractor.stripHTML(html)
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("world"))
        XCTAssertFalse(text.contains("bad()"))
        XCTAssertFalse(text.contains("color:red"))
        XCTAssertFalse(text.contains("<"))
    }

    func testPipelineAdvancesToReadyIndexesAndEmbeds() async throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = try makeBrain(base: base, id: "kb", sourceText: String(repeating: "alpha beta gamma delta ", count: 40))
        let pipeline = IngestPipeline(brainId: "kb", registry: registry, summarizer: FakeSummarizer(), embedder: FakeEmbedder(), maxConcurrent: 4)

        let afterSummarize = try await pipeline.advance()
        XCTAssertEqual(afterSummarize, .reconciling)
        let afterReconcile = try await pipeline.advance()
        XCTAssertEqual(afterReconcile, .embedding)
        let afterEmbed = try await pipeline.advance()
        XCTAssertEqual(afterEmbed, .ready)

        let index = try XCTUnwrap(registry.index(for: "kb"))
        let literature = try await index.listByType("literature")
        XCTAssertGreaterThan(literature.count, 0)
        let semantic = try await index.semanticSearch(query: [1, 0, 0], k: 5)
        XCTAssertGreaterThan(semantic.count, 0)

        let manifest = try BrainManifest.load(from: base.appendingPathComponent("Brains/kb/brain.json"))
        XCTAssertEqual(manifest.ingestStep, .ready)
        XCTAssertEqual(manifest.ingestState, .ready)
        XCTAssertEqual(manifest.embeddingDims, 3)
        XCTAssertEqual(manifest.nodeCount, literature.count)
    }

    func testPipelineReadyStepIsNoOp() async throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = try makeBrain(base: base, id: "kb", sourceText: "alpha beta gamma")
        let pipeline = IngestPipeline(brainId: "kb", registry: registry, summarizer: FakeSummarizer(), embedder: FakeEmbedder(), maxConcurrent: 2)
        _ = try await pipeline.advance()
        _ = try await pipeline.advance()
        let ready = try await pipeline.advance()
        XCTAssertEqual(ready, .ready)
        let again = try await pipeline.advance()
        XCTAssertEqual(again, .ready)
    }
}
