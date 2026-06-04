import Foundation
import os
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "MCPBlockTools")

enum BlockTools {
    private static let validIdCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    private static func validateBlockId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 256 else { return false }
        if id.contains("\\") || id.contains("\0") || id.hasPrefix("/") {
            return false
        }
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        for segment in segments {
            if segment.isEmpty || segment == "." || segment == ".." { return false }
            if !segment.unicodeScalars.allSatisfy({ validIdCharacters.contains($0) }) { return false }
        }
        return true
    }

    private static func genericError(_ tool: String, _ error: Error) -> MCPToolResult {
        logger.error("mcp.tool=\(tool) error=\(error.localizedDescription, privacy: .private)")
        return .error("operation failed")
    }

    static func register(
        blocks: any BlocksRepository,
        tags: any TagsRepository,
        days: any DayRepository,
        indexCoordinator: IndexCoordinator = .shared,
        graphService: BlockGraphService = BlockGraphService()
    ) -> [MCPRegisteredTool] {
        [
            listBlocks(blocks, tags),
            getBlock(blocks, tags),
            getBlockByTitle(blocks),
            searchBlocks(blocks),
            findBacklinks(blocks, indexCoordinator),
            findOrphans(graphService),
            findUnresolvedLinks(graphService),
            listNeighbors(graphService),
            listByType(indexCoordinator),
            listByStatus(indexCoordinator),
            getGraphSnapshot(graphService),
        ]
    }

    private static func listBlocks(_ blocks: any BlocksRepository, _ tags: any TagsRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_blocks",
            description: "List blocks in the knowledge base. Filter by tag_name to narrow. Returns id+title+tag — use get_block for full content.",
            schema: JSONSchemaObject(properties: [
                "tag_name": .string("Filter by tag name"),
                "limit": .integer("Max results to return"),
            ]),
            handler: { args in
                let allBlocks = try await blocks.list()

                var filtered = allBlocks
                if let tagName = args["tag_name"]?.stringValue {
                    let matchKey = TagStore.canonicalName(tagName)
                    filtered = filtered.filter { block in
                        guard let name = block.metadata.tagName else { return false }
                        return TagStore.canonicalName(name) == matchKey
                    }
                }
                if let limit = args["limit"]?.intValue {
                    filtered = Array(filtered.prefix(limit))
                }

                let result = filtered.map { block -> [String: AnyCodableValue] in
                    var entry: [String: AnyCodableValue] = [
                        "id": .string(block.id),
                        "title": .string(block.displayTitle),
                    ]
                    if let name = block.metadata.tagName {
                        entry["tag_name"] = .string(name)
                    }
                if let dayId = block.metadata.dayId {
                    entry["day_id"] = .string(dayId)
                }
                return entry
            }
                return .json(result)
            }
        ).registered
    }

    private static func getBlock(_ blocks: any BlocksRepository, _ tags: any TagsRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "get_block",
            description: "Fetch a block's full markdown by ID (filename like 'Semana-8.md'). Use after list_blocks/search_blocks. If you only have a title, call get_block_by_title first.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Block ID (filename, e.g. 'Semana-8.md')"),
            ], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else {
                    return .error("Missing required parameter: id")
                }
                guard validateBlockId(id) else {
                    return .error("invalid block id")
                }
                let allBlocks = try await blocks.list()
                guard let block = allBlocks.first(where: { $0.id == id }) else {
                    return .error("Block not found: \(id)")
                }
                var result: [String: AnyCodableValue] = [
                    "id": .string(block.id),
                    "title": .string(block.displayTitle),
                    "markdown": .string(block.markdown),
                ]
                if let name = block.metadata.tagName {
                    result["tag_name"] = .string(name)
                }
                if let dayId = block.metadata.dayId {
                    result["day_id"] = .string(dayId)
                }
                result["type"] = .string(block.metadata.type.rawValue)
                return .json(result)
            }
        ).registered
    }

    private static func getBlockByTitle(_ blocks: any BlocksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "get_block_by_title",
            description: "Resolve a wikilink title (e.g., the text inside [[ ]]) to a block ID. Use when you have a title but need an ID for other tools.",
            schema: JSONSchemaObject(properties: [
                "title": .string("Block title to resolve"),
            ], required: ["title"]),
            handler: { args in
                guard let title = args["title"]?.stringValue else {
                    return .error("Missing required parameter: title")
                }
                func norm(_ s: String) -> String {
                    s.lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .precomposedStringWithCanonicalMapping
                }
                let normalized = norm(title)
                let all = try await blocks.list()
                guard let block = all.first(where: { norm($0.displayTitle) == normalized })
                    ?? all.first(where: { norm($0.displayTitle).contains(normalized) })
                else {
                    return .error("No block found matching title: \(title)")
                }
                let result: [String: AnyCodableValue] = [
                    "id": .string(block.id),
                    "title": .string(block.displayTitle),
                    "markdown": .string(block.markdown),
                ]
                return .json(result)
            }
        ).registered
    }

    private static func matchSnippet(_ markdown: String, query: String) -> String {
        var body = markdown
        if body.hasPrefix("---") {
            let afterOpen = body.index(body.startIndex, offsetBy: 3)
            if let close = body.range(of: "\n---", range: afterOpen..<body.endIndex) {
                body = String(body[close.upperBound...])
            }
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = 220
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let tokens = query
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 1 }
        guard let hit = tokens.compactMap({ body.range(of: $0, options: opts)?.lowerBound }).min() else {
            return String(body.prefix(window))
        }
        let hitOffset = body.distance(from: body.startIndex, to: hit)
        let startOffset = max(0, hitOffset - 60)
        let lo = body.index(body.startIndex, offsetBy: startOffset)
        let remaining = body.distance(from: lo, to: body.endIndex)
        let hi = body.index(lo, offsetBy: min(window, remaining))
        var snip = String(body[lo..<hi]).replacingOccurrences(of: "\n", with: " ")
        if startOffset > 0 { snip = "…" + snip }
        if hi < body.endIndex { snip += "…" }
        return snip
    }

    private static func searchBlocks(_ blocks: any BlocksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "search_blocks",
            description: "Full-text search blocks by query. Returns id+title+snippet. Prefer over list_blocks when looking for content matches.",
            schema: JSONSchemaObject(properties: [
                "query": .string("Search query"),
            ], required: ["query"]),
            handler: { args in
                guard let query = args["query"]?.stringValue else {
                    return .error("Missing required parameter: query")
                }
                let results = try await blocks.search(matching: query)
                let items = results.map { block -> [String: AnyCodableValue] in
                    return [
                        "id": .string(block.id),
                        "title": .string(block.displayTitle),
                        "snippet": .string(Self.matchSnippet(block.markdown, query: query)),
                    ]
                }
                return .json(items)
            }
        ).registered
    }

    private static func findBacklinks(_ blocks: any BlocksRepository, _ index: IndexCoordinator) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "find_backlinks",
            description: "Find blocks that link to the given target via [[wikilinks]]. Pass either the target's title or its block_id (block_id is more reliable across renames).",
            schema: JSONSchemaObject(properties: [
                "title": .string("Target block title (text inside [[ ]])"),
                "block_id": .string("Target block ID (filename) — preferred over title"),
            ]),
            handler: { args in
                let providedTitle = args["title"]?.stringValue
                let providedId = args["block_id"]?.stringValue
                let resolvedTitle: String
                if let id = providedId, !id.isEmpty {
                    guard validateBlockId(id) else {
                        return .error("invalid block id")
                    }
                    let all = try await blocks.list()
                    guard let block = all.first(where: { $0.id == id }) else {
                        return .error("Block not found: \(id)")
                    }
                    resolvedTitle = block.displayTitle
                } else if let title = providedTitle, !title.isEmpty {
                    resolvedTitle = title
                } else {
                    return .error("Provide either 'title' or 'block_id'.")
                }
                let entries = await index.findBacklinks(for: resolvedTitle)
                let items = entries.map { entry -> [String: AnyCodableValue] in
                    [
                        "id": .string(entry.id),
                        "title": .string(entry.title),
                        "snippet": .string(String(entry.content.prefix(200))),
                    ]
                }
                return .json(items)
            }
        ).registered
    }

    private static func findOrphans(_ graph: BlockGraphService) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "find_orphans",
            description: "Return blocks with no incoming or outgoing wikilinks. Useful to surface notes that aren't yet integrated into the knowledge graph.",
            schema: JSONSchemaObject(properties: [:]),
            handler: { _ in
                do {
                    let entries = try await graph.findOrphans()
                    let items = entries.map { entry -> [String: AnyCodableValue] in
                        [
                            "id": .string(entry.id),
                            "title": .string(entry.title),
                        ]
                    }
                    return .json(items)
                } catch {
                    return genericError("find_orphans", error)
                }
            }
        ).registered
    }

    private static func findUnresolvedLinks(_ graph: BlockGraphService) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "find_unresolved_links",
            description: "Return [[wikilinks]] in your notes that point to blocks that don't exist yet. Each item is a writing prompt — these are gaps to fill.",
            schema: JSONSchemaObject(properties: [:]),
            handler: { _ in
                do {
                    let pairs = try await graph.findUnresolvedLinks()
                    let items = pairs.map { pair -> [String: AnyCodableValue] in
                        [
                            "source_id": .string(pair.source.id),
                            "source_title": .string(pair.source.title),
                            "target_title": .string(pair.targetTitle),
                        ]
                    }
                    return .json(items)
                } catch {
                    return genericError("find_unresolved_links", error)
                }
            }
        ).registered
    }

    private static func listNeighbors(_ graph: BlockGraphService) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_neighbors",
            description: "Return all blocks linking to or linked-from the given block. Use to explore the local neighborhood around a note.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Block ID (filename)"),
            ], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else {
                    return .error("Missing required parameter: id")
                }
                do {
                    let result = try await graph.findNeighbors(of: id)
                    let incoming = result.incoming.map { entry -> [String: AnyCodableValue] in
                        ["id": .string(entry.id), "title": .string(entry.title)]
                    }
                    let outgoing = result.outgoing.map { entry -> [String: AnyCodableValue] in
                        ["id": .string(entry.id), "title": .string(entry.title)]
                    }
                    let payload: [String: AnyCodableValue] = [
                        "incoming": .array(incoming.map { .object($0) }),
                        "outgoing": .array(outgoing.map { .object($0) }),
                    ]
                    return .json(payload)
                } catch {
                    return genericError("list_neighbors", error)
                }
            }
        ).registered
    }

    private static func listByType(_ index: IndexCoordinator) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_by_type",
            description: "List blocks of a Zettelkasten type: fleeting (capture), literature (source), permanent (evergreen idea), moc (Map of Content), project (active work). Use to find e.g. all permanent notes.",
            schema: JSONSchemaObject(properties: [
                "type": .string("Block type", enum: ["fleeting", "literature", "permanent", "moc", "project"]),
            ], required: ["type"]),
            handler: { args in
                guard let type = args["type"]?.stringValue else {
                    return .error("Missing required parameter: type")
                }
                let validTypes: Set<String> = ["fleeting", "literature", "permanent", "moc", "project"]
                let normalized = type.lowercased()
                guard validTypes.contains(normalized) else {
                    return .error("Invalid type: \(type)")
                }
                let entries = await index.fetchBlocks(byType: normalized)
                let items = entries.map { entry -> [String: AnyCodableValue] in
                    var payload: [String: AnyCodableValue] = [
                        "id": .string(entry.id),
                        "title": .string(entry.title),
                    ]
                    if let status = entry.status {
                        payload["status"] = .string(status)
                    }
                    return payload
                }
                return .json(items)
            }
        ).registered
    }

    private static func listByStatus(_ index: IndexCoordinator) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_by_status",
            description: "List blocks by lifecycle status: active, evergreen, archived, draft.",
            schema: JSONSchemaObject(properties: [
                "status": .string("Block status"),
            ], required: ["status"]),
            handler: { args in
                guard let status = args["status"]?.stringValue else {
                    return .error("Missing required parameter: status")
                }
                let normalized = status.lowercased()
                let entries = await index.fetchBlocks(byStatus: normalized)
                let items = entries.map { entry -> [String: AnyCodableValue] in
                    [
                        "id": .string(entry.id),
                        "title": .string(entry.title),
                        "type": .string(entry.type),
                    ]
                }
                return .json(items)
            }
        ).registered
    }

    private static func getGraphSnapshot(_ graph: BlockGraphService) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "get_graph_snapshot",
            description: "Return all nodes and edges of the knowledge graph as JSON. Pass limit to take the top-N nodes by incoming-link weight (most-referenced first).",
            schema: JSONSchemaObject(properties: [
                "limit": .integer("Max nodes to include, sorted by weight desc"),
            ]),
            handler: { args in
                do {
                    let snapshot = try await graph.loadGraph()
                    var nodes = snapshot.graph.nodes
                    var keepIds: Set<UUID>? = nil
                    if let limit = args["limit"]?.intValue, limit >= 0 {
                        let sorted = nodes.sorted { $0.weight > $1.weight }
                        nodes = Array(sorted.prefix(limit))
                        keepIds = Set(nodes.map(\.id))
                    }
                    let nodeItems = nodes.compactMap { node -> [String: AnyCodableValue]? in
                        guard let stringId = snapshot.idLookup[node.id] else { return nil }
                        return [
                            "id": .string(stringId),
                            "title": .string(node.title),
                            "type": .string(node.type.rawValue),
                            "layer": .string(node.layer.rawValue),
                            "weight": .int(node.weight),
                        ]
                    }
                    let edgeItems = snapshot.graph.edges.compactMap { edge -> [String: AnyCodableValue]? in
                        if let keep = keepIds {
                            guard keep.contains(edge.sourceId) else { return nil }
                            if let target = edge.targetId, !keep.contains(target) { return nil }
                        }
                        guard let sourceString = snapshot.idLookup[edge.sourceId] else { return nil }
                        var item: [String: AnyCodableValue] = [
                            "source_id": .string(sourceString),
                            "target_title": .string(edge.targetTitle),
                        ]
                        if let target = edge.targetId, let resolved = snapshot.idLookup[target] {
                            item["target_id"] = .string(resolved)
                        } else {
                            item["target_id"] = .null
                        }
                        return item
                    }
                    let payload: [String: AnyCodableValue] = [
                        "nodes": .array(nodeItems.map { .object($0) }),
                        "edges": .array(edgeItems.map { .object($0) }),
                    ]
                    return .json(payload)
                } catch {
                    return genericError("get_graph_snapshot", error)
                }
            }
        ).registered
    }
}
