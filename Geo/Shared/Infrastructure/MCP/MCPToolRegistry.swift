import Foundation

typealias MCPToolHandler = @Sendable ([String: AnyCodableValue]) async throws -> MCPToolResult

struct MCPRegisteredTool: Sendable {
    let definition: MCPToolDefinition
    let handler: MCPToolHandler
}

struct BrainCallContext: Sendable {
    let brainId: String
    let index: BrainIndex

    @TaskLocal static var current: BrainCallContext?
}

final class MCPToolRegistry: Sendable {
    static let brainScopedReadTools: Set<String> = [
        "search_blocks", "get_block", "get_block_by_title", "list_blocks",
        "list_by_type", "list_by_status", "find_backlinks", "find_orphans",
        "find_unresolved_links", "list_neighbors", "get_graph_snapshot",
        "list_brains", "get_brain_manifest",
    ]

    private let tools: [String: MCPRegisteredTool]
    private let brains: BrainRegistry

    init(tools: [MCPRegisteredTool], brains: BrainRegistry = .shared) {
        var map: [String: MCPRegisteredTool] = [:]
        for tool in tools {
            map[tool.definition.name] = tool
        }
        self.tools = map
        self.brains = brains
    }

    var definitions: [MCPToolDefinition] {
        tools.values.map(\.definition).sorted { $0.name < $1.name }
    }

    func call(name: String, arguments: [String: AnyCodableValue]) async throws -> MCPToolResult {
        guard let tool = tools[name] else {
            return .error("Unknown tool: \(name)")
        }
        guard let brainId = arguments["brain"]?.stringValue, brainId != BrainRegistry.personalId else {
            return try await tool.handler(arguments)
        }
        guard Self.brainScopedReadTools.contains(name) else {
            return .error("Tool '\(name)' is read-only-blocked on domain brains; only the personal brain is writable.")
        }
        guard let index = brains.index(for: brainId) else {
            return .error("Unknown brain: \(brainId)")
        }
        return try await BrainCallContext.$current.withValue(BrainCallContext(brainId: brainId, index: index)) {
            try await tool.handler(arguments)
        }
    }
}

struct MCPToolBuilder {
    let name: String
    let description: String
    let schema: JSONSchemaObject
    let handler: MCPToolHandler

    var registered: MCPRegisteredTool {
        MCPRegisteredTool(
            definition: MCPToolDefinition(name: name, description: description, inputSchema: schema),
            handler: handler
        )
    }
}
