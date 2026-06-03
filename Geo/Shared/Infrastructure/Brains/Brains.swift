import Foundation
import Accelerate

enum BrainKind: String, Codable, Sendable {
    case essence
    case domain
}

enum BrainIngestState: String, Codable, Sendable {
    case empty
    case ingesting
    case ready
    case failed
}

enum BrainIngestStep: String, Codable, Sendable {
    case pending
    case summarizing
    case reconciling
    case embedding
    case ready
    case failed
}

struct BrainManifest: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let id: String
    var title: String
    var gist: String
    var kind: BrainKind
    var sourceCount: Int
    var nodeCount: Int
    var ingestState: BrainIngestState
    var ingestStep: BrainIngestStep?
    var lastError: String?
    var embeddingModel: String?
    var embeddingDims: Int?
    var schemaVersion: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        title: String,
        gist: String = "",
        kind: BrainKind = .domain,
        sourceCount: Int = 0,
        nodeCount: Int = 0,
        ingestState: BrainIngestState = .empty,
        ingestStep: BrainIngestStep? = nil,
        lastError: String? = nil,
        embeddingModel: String? = nil,
        embeddingDims: Int? = nil,
        schemaVersion: Int = BrainManifest.currentSchemaVersion,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.gist = gist
        self.kind = kind
        self.sourceCount = sourceCount
        self.nodeCount = nodeCount
        self.ingestState = ingestState
        self.ingestStep = ingestStep
        self.lastError = lastError
        self.embeddingModel = embeddingModel
        self.embeddingDims = embeddingDims
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension BrainManifest {
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func load(from url: URL) throws -> BrainManifest {
        try makeDecoder().decode(BrainManifest.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.makeEncoder().encode(self).write(to: url, options: .atomic)
    }
}

struct BrainPaths: Sendable {
    let id: String
    let folder: URL
    let blocksDir: URL
    let sourcesDir: URL
    let indexURL: URL
    let manifestURL: URL
}

protocol BrainIndex: Sendable {
    var id: String { get }
    func get(blockId: String) async throws -> BlockIndexEntry?
    func lexicalSearch(_ query: String, limit: Int) async throws -> [BlockIndexEntry]
    func semanticSearch(query embedding: [Float], k: Int) async throws -> [(id: String, score: Float)]
    func listByType(_ type: String) async throws -> [BlockIndexEntry]
}

final class DatabaseBrainIndex: BrainIndex, @unchecked Sendable {
    let id: String
    private let database: DatabaseService

    init(id: String, database: DatabaseService) {
        self.id = id
        self.database = database
    }

    func get(blockId: String) async throws -> BlockIndexEntry? {
        try await database.fetchBlocks(ids: [blockId]).first
    }

    func lexicalSearch(_ query: String, limit: Int) async throws -> [BlockIndexEntry] {
        let ranked = try await database.searchBlockIds(matching: query)
        let limited = Array(ranked.prefix(max(0, limit)))
        guard !limited.isEmpty else { return [] }
        let entries = try await database.fetchBlocks(ids: limited)
        let order = Dictionary(uniqueKeysWithValues: limited.enumerated().map { ($1, $0) })
        return entries.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    func semanticSearch(query embedding: [Float], k: Int) async throws -> [(id: String, score: Float)] {
        guard k > 0, !embedding.isEmpty else { return [] }
        let candidates = try await database.loadAllVectors()
        guard !candidates.isEmpty else { return [] }
        return VectorMath.topK(query: embedding, candidates: candidates, k: k)
    }

    func listByType(_ type: String) async throws -> [BlockIndexEntry] {
        try await database.fetchBlocks(byType: type)
    }
}

final class BrainRegistry: @unchecked Sendable {
    static let personalId = "essence"
    static let shared = BrainRegistry()

    private let baseURL: URL
    private let fileManager: FileManager
    private var manifestsById: [String: BrainManifest]
    private let cacheLock = NSLock()
    private var indexCache: [String: BrainIndex] = [:]

    init(baseURL: URL? = nil, fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let resolvedBase = baseURL ?? appSupport.appendingPathComponent("Geo")
        self.baseURL = resolvedBase
        self.fileManager = fileManager
        self.manifestsById = Self.discover(baseURL: resolvedBase, fileManager: fileManager)
    }

    private var brainsRoot: URL { baseURL.appendingPathComponent("Brains") }

    private static func discover(baseURL: URL, fileManager: FileManager) -> [String: BrainManifest] {
        var result: [String: BrainManifest] = [personalId: essenceManifest()]
        let root = baseURL.appendingPathComponent("Brains")
        let dirs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let manifestURL = dir.appendingPathComponent("brain.json")
            guard let manifest = try? BrainManifest.load(from: manifestURL), manifest.id != personalId else { continue }
            result[manifest.id] = manifest
        }
        return result
    }

    private static func essenceManifest() -> BrainManifest {
        BrainManifest(
            id: personalId,
            title: "Essence",
            gist: "The personal Zettelkasten — the only writable, growing brain.",
            kind: .essence,
            ingestState: .ready
        )
    }

    func isPersonal(_ id: String) -> Bool { id == Self.personalId }

    func manifest(_ id: String) -> BrainManifest? { manifestsById[id] }

    func list() -> [BrainManifest] {
        manifestsById.values.sorted {
            ($0.kind == .essence ? 0 : 1, $0.title.lowercased()) < ($1.kind == .essence ? 0 : 1, $1.title.lowercased())
        }
    }

    func paths(_ id: String) -> BrainPaths? {
        guard manifestsById[id] != nil else { return nil }
        if isPersonal(id) {
            return BrainPaths(
                id: id,
                folder: baseURL,
                blocksDir: baseURL.appendingPathComponent("Blocks"),
                sourcesDir: baseURL.appendingPathComponent("Blocks"),
                indexURL: baseURL.appendingPathComponent("Index/blocks.sqlite"),
                manifestURL: brainsRoot.appendingPathComponent("\(Self.personalId)/brain.json")
            )
        }
        let folder = brainsRoot.appendingPathComponent(id)
        return BrainPaths(
            id: id,
            folder: folder,
            blocksDir: folder.appendingPathComponent("Blocks"),
            sourcesDir: folder.appendingPathComponent("sources"),
            indexURL: folder.appendingPathComponent("index.sqlite"),
            manifestURL: folder.appendingPathComponent("brain.json")
        )
    }

    func database(for id: String) -> DatabaseService? {
        guard let paths = paths(id) else { return nil }
        return isPersonal(id) ? .shared : DatabaseService(databaseURL: paths.indexURL, schema: .domain)
    }

    func index(for id: String) -> BrainIndex? {
        guard manifestsById[id] != nil else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = indexCache[id] { return cached }
        guard let database = database(for: id) else { return nil }
        let index: BrainIndex = DatabaseBrainIndex(id: id, database: database)
        indexCache[id] = index
        return index
    }
}

enum VectorMath {
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, n)
        var sumSqA: Float = 0
        vDSP_svesq(a, 1, &sumSqA, n)
        var sumSqB: Float = 0
        vDSP_svesq(b, 1, &sumSqB, n)
        let denom = sumSqA.squareRoot() * sumSqB.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    static func topK(query: [Float], candidates: [(id: String, vector: [Float])], k: Int) -> [(id: String, score: Float)] {
        guard k > 0 else { return [] }
        let scored = candidates.map { (id: $0.id, score: cosineSimilarity(query, $0.vector)) }
        return Array(scored.sorted { $0.score > $1.score }.prefix(k))
    }
}
