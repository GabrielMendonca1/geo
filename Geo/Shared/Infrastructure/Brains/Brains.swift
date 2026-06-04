import Foundation

enum BrainKind: String, Sendable {
    case essence
    case domain
}

// A brain is a plain Obsidian-style folder of .md notes under ~/Geo/Brains/<id>/ — the files
// are the source of truth. The manifest is the flat `.brain.json` the CLI (brain.py) and the
// in-app vault store write; this registry only READS it for awareness (list_brains / get_brain_manifest).
struct BrainManifest: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var gist: String
    var kind: BrainKind
    var nodeCount: Int
    var sourceCount: Int

    var state: String { (kind == .essence || nodeCount > 0) ? "ready" : "empty" }

    init(id: String, title: String, gist: String = "", kind: BrainKind = .domain, nodeCount: Int = 0, sourceCount: Int = 0) {
        self.id = id
        self.title = title
        self.gist = gist
        self.kind = kind
        self.nodeCount = nodeCount
        self.sourceCount = sourceCount
    }

    private enum CodingKeys: String, CodingKey { case id, title, gist, nodes, sources }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        gist = try c.decodeIfPresent(String.self, forKey: .gist) ?? ""
        nodeCount = try c.decodeIfPresent(Int.self, forKey: .nodes) ?? 0
        sourceCount = (try c.decodeIfPresent([String].self, forKey: .sources))?.count ?? 0
        kind = .domain
    }

    static func load(from url: URL) throws -> BrainManifest {
        try JSONDecoder().decode(BrainManifest.self, from: Data(contentsOf: url))
    }
}

// Read-only awareness over ~/Geo/Brains. Domain brains are searched by the agent reading their
// .md files directly (Grep/Read) — there is no per-brain index or MCP search routing.
final class BrainRegistry: @unchecked Sendable {
    static let personalId = "essence"
    static let shared = BrainRegistry()

    private let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var manifestsById: [String: BrainManifest]

    init(root: URL? = nil, fileManager: FileManager = .default) {
        let resolved = root ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Geo/Brains")
        self.root = resolved
        self.fileManager = fileManager
        self.manifestsById = Self.discover(root: resolved, fileManager: fileManager)
    }

    private static func discover(root: URL, fileManager: FileManager) -> [String: BrainManifest] {
        var result: [String: BrainManifest] = [personalId: essenceManifest()]
        let dirs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let manifestURL = dir.appendingPathComponent(".brain.json")
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
            kind: .essence
        )
    }

    func reload() {
        let fresh = Self.discover(root: root, fileManager: fileManager)
        lock.lock(); manifestsById = fresh; lock.unlock()
    }

    func isPersonal(_ id: String) -> Bool { id == Self.personalId }

    func manifest(_ id: String) -> BrainManifest? {
        lock.lock(); defer { lock.unlock() }
        return manifestsById[id]
    }

    func list() -> [BrainManifest] {
        lock.lock()
        let values = Array(manifestsById.values)
        lock.unlock()
        return values.sorted {
            ($0.kind == .essence ? 0 : 1, $0.title.lowercased()) < ($1.kind == .essence ? 0 : 1, $1.title.lowercased())
        }
    }
}
