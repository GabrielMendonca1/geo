import Foundation

typealias MCPToolHandler = @Sendable ([String: AnyCodableValue]) async throws -> MCPToolResult

struct MCPRegisteredTool: Sendable {
    let definition: MCPToolDefinition
    let handler: MCPToolHandler
}

final class MCPToolRegistry: Sendable {
    private let tools: [String: MCPRegisteredTool]

    init(tools: [MCPRegisteredTool]) {
        var map: [String: MCPRegisteredTool] = [:]
        for tool in tools {
            map[tool.definition.name] = tool
        }
        self.tools = map
    }

    var definitions: [MCPToolDefinition] {
        tools.values.map(\.definition).sorted { $0.name < $1.name }
    }

    func call(name: String, arguments: [String: AnyCodableValue]) async throws -> MCPToolResult {
        guard let tool = tools[name] else {
            return .error("Unknown tool: \(name)")
        }
        return try await tool.handler(arguments)
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
