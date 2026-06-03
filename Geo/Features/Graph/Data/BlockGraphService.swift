import Foundation
import SwiftUI
import CryptoKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "BlockGraphService")

final class BlockGraphService: @unchecked Sendable {
    private let indexCoordinator: IndexCoordinator
    private let tagStore: TagStore

    init(indexCoordinator: IndexCoordinator = .shared, tagStore: TagStore? = nil) {
        self.indexCoordinator = indexCoordinator
        if let tagStore {
            self.tagStore = tagStore
        } else {
            self.tagStore = MainActor.assumeIsolated { TagStore.shared }
        }
    }

    func loadGraph() async throws -> (graph: BlockGraph, idLookup: [UUID: String]) {
        let entries = await indexCoordinator.fetchAllBlocks()
        guard !entries.isEmpty else { return (.empty, [:]) }

        let tagColors = await resolveTagColors()
        let result = buildGraph(from: entries, tagColors: tagColors)

        logger.info("loadGraph produced \(result.graph.nodes.count) nodes and \(result.graph.edges.count) edges")
        return result
    }

    func applyDelta(
        previous: (graph: BlockGraph, idLookup: [UUID: String]),
        changedEntries: [BlockIndexEntry],
        removedBlockIds: [String],
        allEntries: () async -> [BlockIndexEntry]
    ) async -> (graph: BlockGraph, idLookup: [UUID: String]) {
        let tagColors = await resolveTagColors()

        var idLookup = previous.idLookup
        var stringToUUID: [String: UUID] = [:]
        stringToUUID.reserveCapacity(idLookup.count + changedEntries.count)
        for (uuid, stringId) in idLookup {
            stringToUUID[stringId] = uuid
        }

        var nodesById: [UUID: GraphNode] = [:]
        nodesById.reserveCapacity(previous.graph.nodes.count)
        for node in previous.graph.nodes {
            nodesById[node.id] = node
        }

        var oldTitleByUUID: [UUID: String] = [:]
        oldTitleByUUID.reserveCapacity(previous.graph.nodes.count)
        for node in previous.graph.nodes {
            oldTitleByUUID[node.id] = node.title
        }

        var affectedTitles: Set<String> = []
        for stringId in removedBlockIds {
            if let uuid = stringToUUID[stringId], let oldTitle = oldTitleByUUID[uuid] {
                let key = Self.normalize(oldTitle)
                if !key.isEmpty { affectedTitles.insert(key) }
            }
        }
        for entry in changedEntries {
            if let uuid = stringToUUID[entry.id], let oldTitle = oldTitleByUUID[uuid] {
                let oldKey = Self.normalize(oldTitle)
                if !oldKey.isEmpty { affectedTitles.insert(oldKey) }
            }
            let newKey = Self.normalize(entry.title)
            if !newKey.isEmpty { affectedTitles.insert(newKey) }
        }

        var removedSet: Set<UUID> = []
        for stringId in removedBlockIds {
            if let uuid = stringToUUID[stringId] {
                removedSet.insert(uuid)
            }
        }

        for entry in changedEntries where stringToUUID[entry.id] == nil {
            let uuid = Self.deterministicUUID(from: entry.id)
            stringToUUID[entry.id] = uuid
            idLookup[uuid] = entry.id
        }

        var changedSourceUUIDs: Set<UUID> = []
        for entry in changedEntries {
            if let uuid = stringToUUID[entry.id] {
                changedSourceUUIDs.insert(uuid)
            }
        }

        var weightDirty: Set<UUID> = []
        var keptEdges: [GraphEdge] = []
        keptEdges.reserveCapacity(previous.graph.edges.count)
        for edge in previous.graph.edges {
            if removedSet.contains(edge.sourceId) || changedSourceUUIDs.contains(edge.sourceId) {
                if let target = edge.targetId { weightDirty.insert(target) }
                continue
            }
            keptEdges.append(edge)
        }

        let needsFreshFetch = !affectedTitles.isEmpty
        var titleIndex: [String: String] = [:]
        if needsFreshFetch {
            let entries = await allEntries()
            titleIndex.reserveCapacity(entries.count)
            for entry in entries {
                if let uuid = stringToUUID[entry.id], removedSet.contains(uuid) { continue }
                let key = Self.normalize(entry.title)
                guard !key.isEmpty else { continue }
                if titleIndex[key] == nil {
                    titleIndex[key] = entry.id
                }
            }
        } else {
            titleIndex.reserveCapacity(nodesById.count + changedEntries.count)
            for (uuid, node) in nodesById {
                if removedSet.contains(uuid) { continue }
                guard let stringId = idLookup[uuid] else { continue }
                let key = Self.normalize(node.title)
                guard !key.isEmpty else { continue }
                if titleIndex[key] == nil {
                    titleIndex[key] = stringId
                }
            }
            for entry in changedEntries {
                let key = Self.normalize(entry.title)
                guard !key.isEmpty else { continue }
                titleIndex[key] = entry.id
            }
        }

        var rebuiltEdges: [GraphEdge] = []
        rebuiltEdges.reserveCapacity(keptEdges.count)
        for edge in keptEdges {
            let normalizedTarget = Self.normalize(edge.targetTitle)
            let targetAffected = affectedTitles.contains(normalizedTarget)
            let pointedToRemoved = edge.targetId.map { removedSet.contains($0) } ?? false
            if !targetAffected && !pointedToRemoved {
                rebuiltEdges.append(edge)
                continue
            }
            let resolvedId: UUID?
            if !normalizedTarget.isEmpty,
               let blockId = titleIndex[normalizedTarget],
               let uuid = stringToUUID[blockId],
               !removedSet.contains(uuid) {
                resolvedId = uuid
            } else {
                resolvedId = nil
            }
            if resolvedId != edge.targetId {
                if let old = edge.targetId { weightDirty.insert(old) }
                if let new = resolvedId { weightDirty.insert(new) }
            }
            rebuiltEdges.append(GraphEdge(
                id: edge.id,
                sourceId: edge.sourceId,
                targetId: resolvedId,
                targetTitle: edge.targetTitle
            ))
        }

        for entry in changedEntries {
            guard let sourceUUID = stringToUUID[entry.id] else { continue }
            let links = Self.extractWikiLinks(from: entry.content)
            for rawTarget in links {
                let resolutionKey = Self.normalize(rawTarget)
                let resolvedId: UUID?
                if !resolutionKey.isEmpty,
                   let blockId = titleIndex[resolutionKey],
                   let uuid = stringToUUID[blockId],
                   !removedSet.contains(uuid) {
                    resolvedId = uuid
                } else {
                    resolvedId = nil
                }
                rebuiltEdges.append(GraphEdge(
                    id: UUID(),
                    sourceId: sourceUUID,
                    targetId: resolvedId,
                    targetTitle: rawTarget
                ))
                if let resolved = resolvedId {
                    weightDirty.insert(resolved)
                }
            }
        }

        for uuid in removedSet {
            nodesById.removeValue(forKey: uuid)
            idLookup.removeValue(forKey: uuid)
        }

        for entry in changedEntries {
            guard let uuid = stringToUUID[entry.id] else { continue }
            let color = Self.nodeColor(for: entry, tagColors: tagColors)
            let type = BlockType(rawValue: entry.type) ?? .fleeting
            let layer = BlockLayer(rawValue: entry.layer) ?? .default
            let priorWeight = nodesById[uuid]?.weight ?? 0
            nodesById[uuid] = GraphNode(
                id: uuid,
                title: entry.title,
                tagColor: color,
                type: type,
                layer: layer,
                weight: priorWeight
            )
        }

        if !weightDirty.isEmpty {
            var incomingCounts: [UUID: Int] = [:]
            for edge in rebuiltEdges {
                guard let target = edge.targetId, weightDirty.contains(target) else { continue }
                incomingCounts[target, default: 0] += 1
            }
            for uuid in weightDirty {
                guard let node = nodesById[uuid] else { continue }
                let newWeight = incomingCounts[uuid, default: 0]
                if newWeight != node.weight {
                    nodesById[uuid] = GraphNode(
                        id: node.id,
                        title: node.title,
                        tagColor: node.tagColor,
                        type: node.type,
                        layer: node.layer,
                        weight: newWeight
                    )
                }
            }
        }

        let nodes = Array(nodesById.values)
        let graph = BlockGraph(nodes: nodes, edges: rebuiltEdges)
        return (graph, idLookup)
    }

    func buildGraph(from rawEntries: [BlockIndexEntry], tagColors: [String: Color]) -> (graph: BlockGraph, idLookup: [UUID: String]) {
        let entries = rawEntries.filter { !$0.id.hasPrefix("Daily/") }
        guard !entries.isEmpty else { return (.empty, [:]) }

        var idMap: [String: UUID] = [:]
        idMap.reserveCapacity(entries.count)
        for entry in entries {
            idMap[entry.id] = Self.deterministicUUID(from: entry.id)
        }

        var idLookup: [UUID: String] = [:]
        idLookup.reserveCapacity(entries.count)
        for (stringId, uuid) in idMap {
            idLookup[uuid] = stringId
        }

        var titleIndex: [String: String] = [:]
        titleIndex.reserveCapacity(entries.count)
        for entry in entries {
            let key = Self.normalize(entry.title)
            guard !key.isEmpty else { continue }
            if titleIndex[key] == nil {
                titleIndex[key] = entry.id
            }
        }

        var edges: [GraphEdge] = []
        var incoming: [UUID: Int] = [:]

        for entry in entries {
            guard let sourceUUID = idMap[entry.id] else { continue }
            let links = Self.extractWikiLinks(from: entry.content)
            for rawTarget in links {
                let resolutionKey = Self.normalize(rawTarget)
                let resolvedId: UUID?
                if !resolutionKey.isEmpty,
                   let blockId = titleIndex[resolutionKey],
                   let uuid = idMap[blockId] {
                    resolvedId = uuid
                } else {
                    resolvedId = nil
                }
                let edge = GraphEdge(
                    id: UUID(),
                    sourceId: sourceUUID,
                    targetId: resolvedId,
                    targetTitle: rawTarget
                )
                edges.append(edge)
                if let resolved = resolvedId {
                    incoming[resolved, default: 0] += 1
                }
            }
        }

        var nodes: [GraphNode] = []
        nodes.reserveCapacity(entries.count)
        var emittedNodeIds: Set<UUID> = []
        emittedNodeIds.reserveCapacity(entries.count)
        for entry in entries {
            guard let nodeId = idMap[entry.id] else { continue }
            guard emittedNodeIds.insert(nodeId).inserted else { continue }
            let color = Self.nodeColor(for: entry, tagColors: tagColors)
            let type = BlockType(rawValue: entry.type) ?? .fleeting
            let layer = BlockLayer(rawValue: entry.layer) ?? .default
            let node = GraphNode(
                id: nodeId,
                title: entry.title,
                tagColor: color,
                type: type,
                layer: layer,
                weight: incoming[nodeId, default: 0]
            )
            nodes.append(node)
        }

        return (BlockGraph(nodes: nodes, edges: edges), idLookup)
    }

    @MainActor
    private func snapshotTags() -> [Tag] {
        tagStore.tags
    }

    private func resolveTagColors() async -> [String: Color] {
        let tags = await snapshotTags()
        var map: [String: Color] = [:]
        map.reserveCapacity(tags.count)
        for tag in tags {
            map[TagStore.canonicalName(tag.name)] = Color(
                .sRGB,
                red: tag.color.red,
                green: tag.color.green,
                blue: tag.color.blue,
                opacity: tag.color.alpha
            )
        }
        return map
    }

    private static func nodeColor(for entry: BlockIndexEntry, tagColors: [String: Color]) -> Color? {
        if let name = entry.tags.first {
            return tagColors[TagStore.canonicalName(name)]
        }
        return nil
    }

    func findOrphans() async throws -> [BlockIndexEntry] {
        let entries = await indexCoordinator.fetchAllBlocks()
        return findOrphans(in: entries)
    }

    func findUnresolvedLinks() async throws -> [(source: BlockIndexEntry, targetTitle: String)] {
        let entries = await indexCoordinator.fetchAllBlocks()
        return findUnresolvedLinks(in: entries)
    }

    func findNeighbors(of blockId: String) async throws -> (incoming: [BlockIndexEntry], outgoing: [BlockIndexEntry]) {
        let entries = await indexCoordinator.fetchAllBlocks()
        return findNeighbors(of: blockId, in: entries)
    }

    internal func findOrphans(in entries: [BlockIndexEntry]) -> [BlockIndexEntry] {
        let result = buildGraph(from: entries, tagColors: [:])
        let graph = result.graph
        var hasOutgoing: Set<UUID> = []
        for edge in graph.edges {
            hasOutgoing.insert(edge.sourceId)
        }
        var entryById: [String: BlockIndexEntry] = [:]
        entryById.reserveCapacity(entries.count)
        for entry in entries {
            entryById[entry.id] = entry
        }
        var orphans: [BlockIndexEntry] = []
        for node in graph.nodes {
            guard node.weight == 0, !hasOutgoing.contains(node.id) else { continue }
            guard let stringId = result.idLookup[node.id], let entry = entryById[stringId] else { continue }
            orphans.append(entry)
        }
        return orphans
    }

    internal func findUnresolvedLinks(in entries: [BlockIndexEntry]) -> [(source: BlockIndexEntry, targetTitle: String)] {
        let result = buildGraph(from: entries, tagColors: [:])
        var entryById: [String: BlockIndexEntry] = [:]
        entryById.reserveCapacity(entries.count)
        for entry in entries {
            entryById[entry.id] = entry
        }
        var unresolved: [(source: BlockIndexEntry, targetTitle: String)] = []
        for edge in result.graph.edges where edge.targetId == nil {
            guard let stringId = result.idLookup[edge.sourceId], let source = entryById[stringId] else { continue }
            unresolved.append((source: source, targetTitle: edge.targetTitle))
        }
        return unresolved
    }

    internal func findNeighbors(of blockId: String, in entries: [BlockIndexEntry]) -> (incoming: [BlockIndexEntry], outgoing: [BlockIndexEntry]) {
        let result = buildGraph(from: entries, tagColors: [:])
        var entryById: [String: BlockIndexEntry] = [:]
        entryById.reserveCapacity(entries.count)
        for entry in entries {
            entryById[entry.id] = entry
        }
        let targetUUID = Self.deterministicUUID(from: blockId)
        guard result.graph.nodes.contains(where: { $0.id == targetUUID }) else {
            return ([], [])
        }
        var incomingIds: [String] = []
        var outgoingIds: [String] = []
        var seenIncoming: Set<String> = []
        var seenOutgoing: Set<String> = []
        for edge in result.graph.edges {
            if edge.targetId == targetUUID {
                if let sourceString = result.idLookup[edge.sourceId], !seenIncoming.contains(sourceString) {
                    seenIncoming.insert(sourceString)
                    incomingIds.append(sourceString)
                }
            }
            if edge.sourceId == targetUUID, let resolved = edge.targetId {
                if let targetString = result.idLookup[resolved], !seenOutgoing.contains(targetString) {
                    seenOutgoing.insert(targetString)
                    outgoingIds.append(targetString)
                }
            }
        }
        let incoming = incomingIds.compactMap { entryById[$0] }
        let outgoing = outgoingIds.compactMap { entryById[$0] }
        return (incoming, outgoing)
    }

    private static let linkCacheLock = NSLock()
    private static var linkCache: [Int: (content: String, links: [String])] = [:]
    private static let linkCacheLimit = 20000

    internal static func extractWikiLinks(from content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        let key = content.hashValue
        linkCacheLock.lock()
        if let cached = linkCache[key], cached.content == content {
            linkCacheLock.unlock()
            return cached.links
        }
        linkCacheLock.unlock()
        let parsed = parseWikiLinks(from: content)
        linkCacheLock.lock()
        if linkCache.count >= linkCacheLimit {
            linkCache.removeAll(keepingCapacity: true)
        }
        linkCache[key] = (content: content, links: parsed)
        linkCacheLock.unlock()
        return parsed
    }

    private static func parseWikiLinks(from content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\[\\[([^\\[\\]]+)\\]\\]") else {
            return []
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, options: [], range: range)
        var results: [String] = []
        results.reserveCapacity(matches.count)
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let inner = Range(match.range(at: 1), in: content) else { continue }
            let raw = String(content[inner])
            let pageOnly: String
            if let pipeIdx = raw.firstIndex(of: "|") {
                pageOnly = String(raw[raw.startIndex..<pipeIdx])
            } else {
                pageOnly = raw
            }
            let trimmed = pageOnly.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            results.append(trimmed)
        }
        return results
    }

    internal static func normalize(_ value: String) -> String {
        WikiTitleNormalizer.normalize(value)
    }

    internal static func deterministicUUID(from stringId: String) -> UUID {
        if let parsed = UUID(uuidString: stringId) {
            return parsed
        }
        let digest = SHA256.hash(data: Data(stringId.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
