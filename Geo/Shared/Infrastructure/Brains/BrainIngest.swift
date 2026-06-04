import Foundation
import CryptoKit
import PDFKit
import NaturalLanguage

struct SummarizeContext: Sendable {
    let brainTitle: String
    let brainGist: String
    let sourceLabel: String
}

protocol ChunkSummarizer: Sendable {
    func summarize(_ chunk: String, context: SummarizeContext) async throws -> String
}

final class AnthropicHaikuSummarizer: ChunkSummarizer, @unchecked Sendable {
    func summarize(_ chunk: String, context: SummarizeContext) async throws -> String {
        let system = """
        You distill one chunk of an external source into a single atomic Markdown note for a Zettelkasten knowledge graph.
        Output ONLY Markdown — no code fences, no preamble.
        Line 1 must be '# Title' — a concise, self-contained title for the idea in this chunk.
        Then 2 to 5 sentences in your own words capturing the key idea.
        Wrap every salient concept, entity, method, or term in [[wikilinks]] so the graph connects across notes.
        This chunk is from "\(context.sourceLabel)" in the "\(context.brainTitle)" knowledge base.
        """
        return try await AnthropicClient.complete(system: [(system, true)], user: chunk)
    }
}

protocol EmbeddingService: Sendable {
    var dims: Int { get }
    func embed(_ text: String) async -> [Float]?
}

final class NLEmbeddingService: EmbeddingService, @unchecked Sendable {
    private let embedding: NLEmbedding?

    init() {
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    var dims: Int { embedding?.dimension ?? 0 }

    func embed(_ text: String) async -> [Float]? {
        guard let embedding, let vector = embedding.vector(for: text) else { return nil }
        return vector.map { Float($0) }
    }
}

struct Chunk: Sendable, Equatable {
    let text: String
    let hash: String
    let order: Int
    let sourceLabel: String
}

enum Chunker {
    static func hash(_ text: String) -> String {
        let normalized = text.precomposedStringWithCanonicalMapping
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func chunk(_ text: String, sourceLabel: String, targetWords: Int = 800, overlapWords: Int = 80) -> [Chunk] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).map(String.init)
        guard !words.isEmpty else { return [] }
        let stride = max(1, targetWords - overlapWords)
        var chunks: [Chunk] = []
        var start = 0
        var order = 0
        while start < words.count {
            let end = min(start + targetWords, words.count)
            let slice = words[start..<end].joined(separator: " ")
            chunks.append(Chunk(text: slice, hash: hash(slice), order: order, sourceLabel: sourceLabel))
            order += 1
            if end == words.count { break }
            start += stride
        }
        return chunks
    }
}

enum BrainIngestError: Error, LocalizedError {
    case unknownBrain(String)
    case unsupportedSource(String)

    var errorDescription: String? {
        switch self {
        case .unknownBrain(let id): return "Unknown brain: \(id)"
        case .unsupportedSource(let ext): return "Unsupported source type: .\(ext)"
        }
    }
}

enum SourceExtractor {
    static let supportedExtensions: Set<String> = ["txt", "md", "markdown", "text", "pdf", "html", "htm"]

    static func extractText(from url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown", "text":
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        case "pdf":
            guard let document = PDFDocument(url: url) else { return "" }
            var out = ""
            for index in 0..<document.pageCount {
                if let page = document.page(at: index), let text = page.string {
                    out += text + "\n\n"
                }
            }
            return out
        case "html", "htm":
            let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return stripHTML(raw)
        default:
            throw BrainIngestError.unsupportedSource(url.pathExtension)
        }
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        for tag in ["script", "style"] {
            text = text.replacingOccurrences(of: "(?s)<\(tag)\\b.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum BrainReconciler {
    static func canonicalTitles(forMentions mentions: [String]) -> [String: String] {
        var byKey: [String: [String]] = [:]
        for mention in mentions {
            let key = WikiTitleNormalizer.normalize(mention)
            guard !key.isEmpty else { continue }
            byKey[key, default: []].append(mention)
        }
        var result: [String: String] = [:]
        for (key, variants) in byKey {
            let canonical = variants.sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs < rhs
            }.first ?? key
            result[key] = canonical
        }
        return result
    }

    static func rewriteLinks(in content: String, canonicalByKey: [String: String]) -> String {
        var output = content
        let mentions = BlockGraphService.extractWikiLinks(from: content)
        for mention in Set(mentions) {
            let key = WikiTitleNormalizer.normalize(mention)
            guard let canonical = canonicalByKey[key], canonical != mention else { continue }
            output = output.replacingOccurrences(of: "[[\(mention)]]", with: "[[\(canonical)]]")
            output = output.replacingOccurrences(of: "[[\(mention)|", with: "[[\(canonical)|")
        }
        return output
    }
}

final class IngestPipeline: @unchecked Sendable {
    let brainId: String
    private let registry: BrainRegistry
    private let summarizer: ChunkSummarizer
    private let embedder: EmbeddingService
    private let maxConcurrent: Int

    init(
        brainId: String,
        registry: BrainRegistry = .shared,
        summarizer: ChunkSummarizer = AnthropicHaikuSummarizer(),
        embedder: EmbeddingService = NLEmbeddingService(),
        maxConcurrent: Int = 8
    ) {
        self.brainId = brainId
        self.registry = registry
        self.summarizer = summarizer
        self.embedder = embedder
        self.maxConcurrent = max(1, maxConcurrent)
    }

    @discardableResult
    func advance() async throws -> BrainIngestStep {
        guard let paths = registry.paths(brainId), let database = registry.database(for: brainId) else {
            throw BrainIngestError.unknownBrain(brainId)
        }
        var manifest = (try? BrainManifest.load(from: paths.manifestURL))
            ?? BrainManifest(id: brainId, title: brainId)
        let step = manifest.ingestStep ?? .pending

        do {
            switch step {
            case .pending, .summarizing:
                try await runSummarize(paths: paths, database: database, manifest: &manifest)
                manifest.ingestStep = .reconciling
                manifest.ingestState = .ingesting
            case .reconciling:
                try await runReconcile(paths: paths, database: database)
                manifest.ingestStep = .embedding
                manifest.ingestState = .ingesting
            case .embedding:
                let dims = try await runEmbed(database: database)
                manifest.ingestStep = .ready
                manifest.ingestState = .ready
                if dims > 0 {
                    manifest.embeddingModel = "NLEmbedding"
                    manifest.embeddingDims = dims
                }
            case .ready, .failed:
                break
            }
            manifest.lastError = nil
        } catch {
            manifest.ingestStep = .failed
            manifest.ingestState = .failed
            manifest.lastError = error.localizedDescription
            manifest.updatedAt = Date()
            try? manifest.save(to: paths.manifestURL)
            throw error
        }

        let count = (try? await database.fetchBlocks(byType: "literature").count) ?? manifest.nodeCount
        manifest.nodeCount = count
        manifest.updatedAt = Date()
        try manifest.save(to: paths.manifestURL)
        return manifest.ingestStep ?? .ready
    }

    private func runSummarize(paths: BrainPaths, database: DatabaseService, manifest: inout BrainManifest) async throws {
        try FileManager.default.createDirectory(at: paths.blocksDir, withIntermediateDirectories: true)
        let sources = (try? FileManager.default.contentsOfDirectory(at: paths.sourcesDir, includingPropertiesForKeys: nil)) ?? []
        var chunks: [Chunk] = []
        for source in sources where SourceExtractor.supportedExtensions.contains(source.pathExtension.lowercased()) {
            let text = try SourceExtractor.extractText(from: source)
            chunks.append(contentsOf: Chunker.chunk(text, sourceLabel: source.lastPathComponent))
        }
        let existing = Set((try? await database.fetchBlocks(byType: "literature"))?.map(\.id) ?? [])
        let pending = chunks.filter { !existing.contains("\($0.hash).md") }
        guard !pending.isEmpty else { return }

        let context = SummarizeContext(brainTitle: manifest.title, brainGist: manifest.gist, sourceLabel: "")
        let summarizer = self.summarizer
        let produced = try await mapBounded(pending, max: maxConcurrent) { chunk -> (Chunk, String) in
            let ctx = SummarizeContext(brainTitle: context.brainTitle, brainGist: context.brainGist, sourceLabel: chunk.sourceLabel)
            let markdown = try await summarizer.summarize(chunk.text, context: ctx)
            return (chunk, markdown)
        }

        for (chunk, markdown) in produced {
            let id = "\(chunk.hash).md"
            let title = Self.title(from: markdown)
            let frontmatter = "---\ntype: literature\nlayer: shared\nsource: \(chunk.sourceLabel)\nchunk_hash: \(chunk.hash)\n---\n"
            let fileBody = frontmatter + markdown
            try fileBody.write(to: paths.blocksDir.appendingPathComponent(id), atomically: true, encoding: .utf8)
            let now = Date()
            try await database.upsertBlock(BlockIndexEntry(
                id: id, path: id, title: title, content: markdown,
                createdAt: now, modifiedAt: now, dayId: nil,
                openTaskCount: 0, completedTaskCount: 0, tags: [],
                type: "literature", status: nil, layer: "shared"
            ))
        }
    }

    private func runReconcile(paths: BrainPaths, database: DatabaseService) async throws {
        let nodes = try await database.fetchBlocks(byType: "literature")
        guard !nodes.isEmpty else { return }
        let allMentions = nodes.flatMap { BlockGraphService.extractWikiLinks(from: $0.content) }
        let canonicalByKey = BrainReconciler.canonicalTitles(forMentions: allMentions)
        let titleToId = Dictionary(nodes.map { (WikiTitleNormalizer.normalize($0.title), $0.id) }, uniquingKeysWith: { a, _ in a })

        for node in nodes {
            let rewritten = BrainReconciler.rewriteLinks(in: node.content, canonicalByKey: canonicalByKey)
            if rewritten != node.content {
                let now = Date()
                try await database.upsertBlock(BlockIndexEntry(
                    id: node.id, path: node.path, title: node.title, content: rewritten,
                    createdAt: node.createdAt, modifiedAt: now, dayId: node.dayId,
                    openTaskCount: node.openTaskCount, completedTaskCount: node.completedTaskCount, tags: node.tags,
                    type: node.type, status: node.status, layer: node.layer
                ))
                let frontmatter = "---\ntype: literature\nlayer: shared\n---\n"
                try? (frontmatter + rewritten).write(to: paths.blocksDir.appendingPathComponent(node.id), atomically: true, encoding: .utf8)
            }
            let links = BlockGraphService.extractWikiLinks(from: rewritten)
            let edges = Set(links).map { link -> DatabaseService.BrainEdge in
                let key = WikiTitleNormalizer.normalize(link)
                let targetId = titleToId[key]
                return DatabaseService.BrainEdge(sourceId: node.id, targetTitle: canonicalByKey[key] ?? link, targetId: targetId)
            }
            try await database.setEdges(forSource: node.id, edges: edges)
        }
    }

    @discardableResult
    private func runEmbed(database: DatabaseService) async throws -> Int {
        let nodes = try await database.fetchBlocks(byType: "literature")
        guard !nodes.isEmpty else { return embedder.dims }
        let alreadyEmbedded = Set(try await database.loadAllVectors().map(\.id))
        for node in nodes where !alreadyEmbedded.contains(node.id) {
            if let vector = await embedder.embed(node.title + "\n" + node.content), !vector.isEmpty {
                try await database.upsertVector(blockId: node.id, embedding: vector)
            }
        }
        return embedder.dims
    }

    private func mapBounded<Element: Sendable, Result: Sendable>(
        _ items: [Element],
        max: Int,
        _ transform: @escaping @Sendable (Element) async throws -> Result
    ) async throws -> [Result] {
        var results: [Result] = []
        var nextIndex = 0
        try await withThrowingTaskGroup(of: Result.self) { group in
            let initial = Swift.min(max, items.count)
            for _ in 0..<initial {
                let element = items[nextIndex]
                nextIndex += 1
                group.addTask { try await transform(element) }
            }
            while let result = try await group.next() {
                results.append(result)
                if nextIndex < items.count {
                    let element = items[nextIndex]
                    nextIndex += 1
                    group.addTask { try await transform(element) }
                }
            }
        }
        return results
    }

    private static func title(from markdown: String) -> String {
        for line in markdown.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                return String(trimmed.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))
            }
        }
        return "Untitled"
    }
}
