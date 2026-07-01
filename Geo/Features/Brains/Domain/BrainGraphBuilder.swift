import SwiftUI

// MARK: - Graph mapping (notes + [[wikilinks]] → BlockGraph; reuses the app's GraphView)

enum BrainGraphBuilder {
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]|]+)(?:\|[^\[\]]+)?\]\]"#)

    static func build(notes: [BrainNote]) -> (graph: BlockGraph, lookup: [UUID: BrainNote]) {
        var idForSlug: [String: UUID] = [:]
        var lookup: [UUID: BrainNote] = [:]
        var order: [(note: BrainNote, id: UUID)] = []
        order.reserveCapacity(notes.count)
        for note in notes {
            let id = stableID(for: note.id)
            idForSlug[note.id.lowercased()] = id
            lookup[id] = note
            order.append((note, id))
        }

        var edges: [GraphEdge] = []
        var seen = Set<EdgeKey>()
        var degree: [UUID: Int] = [:]
        for (note, sourceId) in order {
            let body = note.body as NSString
            for m in linkRegex.matches(in: note.body, range: NSRange(location: 0, length: body.length)) {
                let raw = body.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty { continue }
                let key = Self.linkSlug(raw)
                if key.isEmpty || key == "index" || key == note.id.lowercased() { continue }
                if let targetId = idForSlug[key] {
                    if targetId == sourceId { continue }
                    guard seen.insert(EdgeKey(source: sourceId, target: targetId, title: nil)).inserted else { continue }
                    edges.append(GraphEdge(id: stableID(for: "\(sourceId.uuidString)->\(targetId.uuidString)"), sourceId: sourceId, targetId: targetId, targetTitle: raw))
                    degree[sourceId, default: 0] += 1
                    degree[targetId, default: 0] += 1
                } else {
                    guard seen.insert(EdgeKey(source: sourceId, target: nil, title: key)).inserted else { continue }
                    edges.append(GraphEdge(id: stableID(for: "\(sourceId.uuidString)~>\(key)"), sourceId: sourceId, targetId: nil, targetTitle: raw))
                }
            }
        }

        // Floor the weight so unlinked notes (a brand-new vault) still render as
        // visible nodes with labels instead of 5pt specks that fade out when zoomed.
        let nodes = order.map { entry in
            GraphNode(id: entry.id, title: entry.note.title, tagColor: nil, type: .permanent, layer: .agent, weight: max(1, degree[entry.id] ?? 0))
        }
        return (BlockGraph(nodes: nodes, edges: edges), lookup)
    }

    // Deterministic node id for a note slug — lets callers map a selected note to its graph node.
    static func nodeID(forNoteSlug slug: String) -> UUID { stableID(for: slug) }

    // Thin wrappers over BrainGraphCache (build a throwaway cache) — used by tests / one-shot callers.
    // The hot path (graph panel, status bar) holds a cached `BrainGraphCache` and calls it directly.
    static func localSubgraph(_ graph: BlockGraph, around center: UUID, hops: Int = 1) -> BlockGraph {
        BrainGraphCache(graph: graph).localSubgraph(in: graph, around: center, hops: hops)
    }

    static func backlinkCount(_ graph: BlockGraph, to target: UUID) -> Int {
        BrainGraphCache(graph: graph).backlinkCount(to: target)
    }

    private static func linkSlug(_ text: String) -> String {
        let lowered = text.precomposedStringWithCanonicalMapping.lowercased()
        var parts: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            let v = scalar.value
            if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                parts.append(current); current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return String(parts.joined(separator: "-").prefix(60))
    }

    // Deterministic UUID from the note slug (FNV-1a, two seeds → 128 bits) so a rebuild
    // after ingest keeps existing nodes in place and only animates the new ones in.
    private static func stableID(for slug: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for byte in slug.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
            return h
        }
        let hi = fnv(0xcbf29ce484222325).bigEndian
        let lo = fnv(0x100000001b3).bigEndian
        let b = withUnsafeBytes(of: (hi, lo)) { Array($0) }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private struct EdgeKey: Hashable {
        let source: UUID
        let target: UUID?
        let title: String?
    }
}

// Adjacency + incoming-degree derived ONCE from a graph (g-triad #3). The graph panel / status bar
// hold this and read it per selection instead of re-scanning every edge on each call.
struct BrainGraphCache {
    let adjacency: [UUID: Set<UUID>]      // undirected, resolved edges only
    let incomingDegree: [UUID: Int]       // resolved backlinks per node

    static let empty = BrainGraphCache(adjacency: [:], incomingDegree: [:])

    private init(adjacency: [UUID: Set<UUID>], incomingDegree: [UUID: Int]) {
        self.adjacency = adjacency
        self.incomingDegree = incomingDegree
    }

    init(graph: BlockGraph) {
        var adjacency: [UUID: Set<UUID>] = [:]
        var incoming: [UUID: Int] = [:]
        for edge in graph.edges {
            guard let target = edge.targetId else { continue }
            adjacency[edge.sourceId, default: []].insert(target)
            adjacency[target, default: []].insert(edge.sourceId)
            incoming[target, default: 0] += 1
        }
        self.adjacency = adjacency
        self.incomingDegree = incoming
    }

    func backlinkCount(to target: UUID) -> Int { incomingDegree[target] ?? 0 }

    // Node + every node within `hops` undirected steps, plus edges incident to the included set.
    func localSubgraph(in graph: BlockGraph, around center: UUID, hops: Int = 1) -> BlockGraph {
        guard graph.nodes.contains(where: { $0.id == center }) else { return .empty }
        var included: Set<UUID> = [center]
        var frontier: Set<UUID> = [center]
        for _ in 0..<max(0, hops) {
            var next: Set<UUID> = []
            for node in frontier { next.formUnion(adjacency[node] ?? []) }
            next.subtract(included)
            if next.isEmpty { break }
            included.formUnion(next)
            frontier = next
        }
        let nodes = graph.nodes.filter { included.contains($0.id) }
        let edges = graph.edges.filter { edge in
            guard included.contains(edge.sourceId) else { return false }
            return edge.targetId == nil || included.contains(edge.targetId!)
        }
        return BlockGraph(nodes: nodes, edges: edges)
    }
}
