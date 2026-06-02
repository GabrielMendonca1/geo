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

    private static func loadBlock(_ blocks: any BlocksRepository, id: String) async throws -> BlockEntity? {
        try await blocks.get(id: id)
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
            createBlock(blocks, tags, days),
            updateBlock(blocks),
            deleteBlock(blocks),
            setBlockLayer(blocks),
            findBacklinks(blocks, indexCoordinator),
            findOrphans(graphService),
            findUnresolvedLinks(graphService),
            listNeighbors(graphService),
            listByType(indexCoordinator),
            listByStatus(indexCoordinator),
            promoteToPermanent(blocks),
            extractPermanentFrom(blocks),
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
                switch AgentAuthorization.authorize(.read, on: nil, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }
                let allBlocks = try await blocks.list()
                let allTags = try await tags.list()
                let tagMap = Dictionary(uniqueKeysWithValues: allTags.map { ($0.id, $0.name) })

                var filtered = allBlocks
                if let tagName = args["tag_name"]?.stringValue {
                    let matchId = allTags.first { $0.name.caseInsensitiveCompare(tagName) == .orderedSame }?.id
                    filtered = filtered.filter { $0.tagId == matchId }
                }
                if let limit = args["limit"]?.intValue {
                    filtered = Array(filtered.prefix(limit))
                }

                let result = filtered.map { block -> [String: AnyCodableValue] in
                    var entry: [String: AnyCodableValue] = [
                        "id": .string(block.id),
                        "title": .string(block.displayTitle),
                    ]
                    if let tagId = block.tagId, let name = tagMap[tagId] {
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
                switch AgentAuthorization.authorize(.read, on: id, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }
                let allBlocks = try await blocks.list()
                guard let block = allBlocks.first(where: { $0.id == id }) else {
                    return .error("Block not found: \(id)")
                }
                let allTags = try await tags.list()
                var result: [String: AnyCodableValue] = [
                    "id": .string(block.id),
                    "title": .string(block.displayTitle),
                    "markdown": .string(block.markdown),
                ]
                if let tagId = block.tagId, let tag = allTags.first(where: { $0.id == tagId }) {
                    result["tag_name"] = .string(tag.name)
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
                switch AgentAuthorization.authorize(.read, on: nil, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
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
                switch AgentAuthorization.authorize(.read, on: nil, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
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

    private static func createBlock(_ blocks: any BlocksRepository, _ tags: any TagsRepository, _ days: any DayRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "create_block",
            description: "Create a new markdown block (note). Auto-prepends '# title' if missing and links to today's day record. Optionally classify by Zettelkasten type and lifecycle status — these go into the typed sidecar, NOT into the markdown body. Returns the new block's ID.",
            schema: JSONSchemaObject(properties: [
                "title": .string("Block title"),
                "content": .string("Markdown content (title will be prepended as # heading if not present)"),
                "tag_name": .string("Tag name to assign"),
                "day_id": .string("Day to link to (YYYY-MM-DD). Defaults to today."),
                "type": .string("Zettelkasten classification: fleeting | literature | permanent | moc | project. Default: fleeting."),
                "status": .string("Lifecycle status: active | evergreen | archived | draft. Default: none."),
                "layer": .string("Write layer: agent | review | shared. Default: review for agent-created notes."),
            ], required: ["title", "content"]),
            handler: { args in
                guard let title = args["title"]?.stringValue,
                      let content = args["content"]?.stringValue else {
                    return .error("Missing required parameters: title, content")
                }
                let layerRaw = args["layer"]?.stringValue?.lowercased() ?? BlockLayer.review.rawValue
                guard let requestedLayer = BlockLayer(rawValue: layerRaw) else {
                    return .error("Invalid layer for agent-created block: \(layerRaw). Use agent, review, or shared.")
                }
                switch AgentAuthorization.authorize(.create, on: nil, layer: requestedLayer) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }

                var markdown = content
                if !markdown.hasPrefix("#") {
                    markdown = "# \(title)\n\(content)"
                }

                let block = try await blocks.create(title: title, markdown: markdown)

                if let tagName = args["tag_name"]?.stringValue {
                    let allTags = try await tags.list()
                    if let tag = allTags.first(where: { $0.name.caseInsensitiveCompare(tagName) == .orderedSame }) {
                        try await blocks.setTag(blockId: block.id, tagId: tag.id)
                    }
                }

                let dayId = args["day_id"]?.stringValue
                let formatter = DateFormatters.iso8601FullDate
                let date: Date
                if let dayId, let parsed = formatter.date(from: dayId) {
                    date = parsed
                } else {
                    date = Date()
                }
                try await days.addBlockToDay(date: date, blockId: block.id)

                if let typeRaw = args["type"]?.stringValue {
                    let validTypes: Set<String> = ["fleeting", "literature", "permanent", "moc", "project"]
                    guard validTypes.contains(typeRaw.lowercased()) else {
                        return .error("Invalid type: \(typeRaw). Must be one of: fleeting, literature, permanent, moc, project.")
                    }
                    if let blockType = BlockType(rawValue: typeRaw.lowercased()) {
                        try await blocks.setType(blockId: block.id, type: blockType)
                    }
                }
                if let statusRaw = args["status"]?.stringValue {
                    try await blocks.setStatus(blockId: block.id, status: statusRaw.lowercased())
                }
                try await blocks.setLayer(blockId: block.id, layer: requestedLayer)

                return .json(["id": block.id, "title": block.displayTitle])
            }
        ).registered
    }

    private static func updateBlock(_ blocks: any BlocksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "update_block",
            description: "Replace a block's full markdown content by ID. Overwrites the entire body — read first with get_block if you only want to edit part.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Block ID (filename)"),
                "content": .string("New markdown content"),
            ], required: ["id", "content"]),
            handler: { args in
                guard let id = args["id"]?.stringValue,
                      let content = args["content"]?.stringValue else {
                    return .error("Missing required parameters: id, content")
                }
                guard validateBlockId(id) else {
                    return .error("invalid block id")
                }
                guard let block = try await loadBlock(blocks, id: id) else {
                    return .error("Block not found: \(id)")
                }
                switch AgentAuthorization.authorize(.update, on: id, layer: block.metadata.layer) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }

                let incoming = MarkdownConverter.shared.parse(content)
                let currentFM = MarkdownConverter.shared.parse(block.markdown).frontmatter
                var frontmatterMerge: [String: AnyCodableValue] = [:]
                var frontmatterChanged = false
                for (key, value) in incoming.frontmatter {
                    if key == "frontmatter_version" { continue }
                    frontmatterMerge[key] = .string(value)
                    if currentFM[key] != value {
                        frontmatterChanged = true
                    }
                }
                for key in currentFM.keys where key != "frontmatter_version" {
                    if incoming.frontmatter[key] == nil {
                        frontmatterChanged = true
                    }
                }

                if frontmatterChanged {
                    _ = try await blocks.mutateFrontmatter(blockId: id, merge: frontmatterMerge)
                    guard let refreshed = try await loadBlock(blocks, id: id) else {
                        return .error("Block not found after frontmatter mutation: \(id)")
                    }
                    let refreshedDoc = MarkdownConverter.shared.parse(refreshed.markdown)
                    let bodyOnly = incoming.body
                    let merged = reassembleMarkdown(frontmatter: refreshedDoc.frontmatter, body: bodyOnly)
                    try await blocks.update(id: id, markdown: merged)
                } else {
                    try await blocks.update(id: id, markdown: content)
                }
                return .json(["success": true])
            }
        ).registered
    }

    private static func reassembleMarkdown(frontmatter: [String: String], body: String) -> String {
        guard !frontmatter.isEmpty else { return body }
        var out = "---\n"
        for key in frontmatter.keys.sorted() {
            guard let value = frontmatter[key] else { continue }
            out += "\(key): \(value)\n"
        }
        out += "---\n"
        let trimmedBody = body.hasPrefix("\n") ? String(body.dropFirst()) : body
        return out + trimmedBody
    }

    private static func deleteBlock(_ blocks: any BlocksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "delete_block",
            description: "Permanently delete a block by ID. Irreversible — confirm intent before calling. Wikilinks pointing to it will become unresolved.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Block ID (filename)"),
            ], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else {
                    return .error("Missing required parameter: id")
                }
                guard validateBlockId(id) else {
                    return .error("invalid block id")
                }
                guard let block = try await loadBlock(blocks, id: id) else {
                    return .error("Block not found: \(id)")
                }
                switch AgentAuthorization.authorize(.delete, on: id, layer: block.metadata.layer) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }
                try await blocks.delete(id: id)
                return .json(["success": true])
            }
        ).registered
    }

    private static func setBlockLayer(_ blocks: any BlocksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "set_layer",
            description: "Promote a block's write layer so the agent can edit it. Valid targets: agent | review | shared. Demotion to 'user' is not permitted via the agent — the user must do that in-app.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Block ID (filename)"),
                "layer": .string("Target layer: agent | review | shared"),
            ], required: ["id", "layer"]),
            handler: { args in
                guard let id = args["id"]?.stringValue,
                      let layerRaw = args["layer"]?.stringValue?.lowercased() else {
                    return .error("Missing required parameters: id, layer")
                }
                guard validateBlockId(id) else {
                    return .error("invalid block id")
                }
                guard let targetLayer = BlockLayer(rawValue: layerRaw) else {
                    return .error("Invalid layer: \(layerRaw). Use agent, review, or shared.")
                }
                guard try await loadBlock(blocks, id: id) != nil else {
                    return .error("Block not found: \(id)")
                }
                switch AgentAuthorization.authorize(.setLayer, on: id, layer: targetLayer) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }
                try await blocks.setLayer(blockId: id, layer: targetLayer)
                return .json(["success": true])
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
                switch AgentAuthorization.authorize(.read, on: nil, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }
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
                switch AgentAuthorization.authorize(.read, on: nil, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }
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
                switch AgentAuthorization.authorize(.read, on: nil, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }
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
                switch AgentAuthorization.authorize(.read, on: id, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
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
                switch AgentAuthorization.authorize(.read, on: nil, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
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
                switch AgentAuthorization.authorize(.read, on: nil, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
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

    private static func promoteToPermanent(_ blocks: any BlocksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "promote_to_permanent",
            description: "Mark a block as a permanent (evergreen) Zettelkasten note. Sets type=permanent and status=evergreen. Use when a fleeting/literature note has matured into a standalone idea worth keeping.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Block ID (filename)"),
            ], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else {
                    return .error("Missing required parameter: id")
                }
                guard validateBlockId(id) else {
                    return .error("invalid block id")
                }
                guard let target = try await loadBlock(blocks, id: id) else {
                    return .error("Block not found: \(id)")
                }
                switch AgentAuthorization.authorize(.setType, on: id, layer: target.metadata.layer) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }
                do {
                    try await blocks.setType(blockId: id, type: .permanent)
                    try await blocks.setStatus(blockId: id, status: "evergreen")
                    return .json(["success": true])
                } catch {
                    return genericError("promote_to_permanent", error)
                }
            }
        ).registered
    }

    private static func extractPermanentFrom(_ blocks: any BlocksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "extract_permanent_from",
            description: "Extract a new permanent note from an existing project, archiving the project. The new note starts with 'Extraído de [[<project title>]]' so the link back is automatic. Use to crystallize lessons from completed work.",
            schema: JSONSchemaObject(properties: [
                "id": .string("Source block ID (filename)"),
            ], required: ["id"]),
            handler: { args in
                guard let id = args["id"]?.stringValue else {
                    return .error("Missing required parameter: id")
                }
                guard validateBlockId(id) else {
                    return .error("invalid block id")
                }
                do {
                    guard let source = try await loadBlock(blocks, id: id) else {
                        return .error("Block not found: \(id)")
                    }
                    switch AgentAuthorization.authorize(.setStatus, on: id, layer: source.metadata.layer) {
                    case .allow: break
                    case .deny(let reason): return .error(reason)
                    }
                    let sourceTitle = source.displayTitle
                    let body = "# Extraído de [[\(sourceTitle)]]\n\n"
                    let newBlock = try await blocks.create(title: "", markdown: body)
                    try await blocks.setType(blockId: newBlock.id, type: .permanent)
                    try await blocks.setLayer(blockId: newBlock.id, layer: .review)
                    try await blocks.setStatus(blockId: id, status: "archived")
                    return .json([
                        "id": .string(newBlock.id),
                        "title": .string(newBlock.displayTitle),
                    ] as [String: AnyCodableValue])
                } catch {
                    return genericError("extract_permanent_from", error)
                }
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
                switch AgentAuthorization.authorize(.read, on: nil, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }
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
