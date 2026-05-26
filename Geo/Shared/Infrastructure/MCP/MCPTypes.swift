import Foundation

enum JSONRPCID: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.typeMismatch(JSONRPCID.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected string, int, or null"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .null: try container.encodeNil()
        }
    }
}

struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: [String: AnyCodableValue]?
}

struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID?
    let result: AnyCodableValue?
    let error: JSONRPCError?

    init(id: JSONRPCID?, result: AnyCodableValue?, error: JSONRPCError?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }

    static func success(id: JSONRPCID?, result: AnyCodableValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    static func error(id: JSONRPCID?, code: Int, message: String, data: AnyCodableValue? = nil) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: JSONRPCError(code: code, message: message, data: data))
    }
}

struct JSONRPCError: Codable, Sendable {
    let code: Int
    let message: String
    let data: AnyCodableValue?

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

struct MCPInitializeResult: Codable, Sendable {
    let protocolVersion: String
    let capabilities: MCPCapabilities
    let serverInfo: MCPServerInfo
}

struct MCPCapabilities: Codable, Sendable {
    let tools: MCPToolsCapability?

    struct MCPToolsCapability: Codable, Sendable {
        let listChanged: Bool?
    }
}

struct MCPServerInfo: Codable, Sendable {
    let name: String
    let version: String
}

struct MCPToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONSchemaObject
}

struct JSONSchemaObject: Codable, Sendable {
    let type: String
    let properties: [String: JSONSchemaProperty]?
    let required: [String]?

    init(properties: [String: JSONSchemaProperty] = [:], required: [String] = []) {
        self.type = "object"
        self.properties = properties.isEmpty ? nil : properties
        self.required = required.isEmpty ? nil : required
    }
}

final class JSONSchemaProperty: Codable, Sendable {
    let type: String?
    let description: String?
    let `enum`: [String]?
    let items: JSONSchemaProperty?
    let properties: [String: JSONSchemaProperty]?
    let required: [String]?

    init(type: String, description: String? = nil, enum enumValues: [String]? = nil, items: JSONSchemaProperty? = nil, properties: [String: JSONSchemaProperty]? = nil, required: [String]? = nil) {
        self.type = type
        self.description = description
        self.enum = enumValues
        self.items = items
        self.properties = properties
        self.required = required
    }

    static func string(_ description: String? = nil, enum enumValues: [String]? = nil) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "string", description: description, enum: enumValues)
    }

    static func integer(_ description: String? = nil) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "integer", description: description)
    }

    static func number(_ description: String? = nil) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "number", description: description)
    }

    static func boolean(_ description: String? = nil) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "boolean", description: description)
    }

    static func array(_ description: String? = nil, items: JSONSchemaProperty) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "array", description: description, items: items)
    }

    static func object(_ description: String? = nil, properties: [String: JSONSchemaProperty], required: [String]? = nil) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "object", description: description, properties: properties, required: required)
    }
}

struct MCPToolCallParams: Codable, Sendable {
    let name: String
    let arguments: [String: AnyCodableValue]?
}

struct MCPToolResult: Codable, Sendable {
    let content: [MCPContent]
    let isError: Bool?

    static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [MCPContent(type: "text", text: text)], isError: nil)
    }

    static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [MCPContent(type: "text", text: message)], isError: true)
    }

    static func json(_ value: some Encodable) -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return .error("Failed to encode result")
        }
        return .text(text)
    }
}

struct MCPContent: Codable, Sendable {
    let type: String
    let text: String
}

enum AnyCodableValue: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: AnyCodableValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.typeMismatch(AnyCodableValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported type"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [AnyCodableValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: AnyCodableValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    static func from(_ encodable: some Encodable) -> AnyCodableValue? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(encodable),
              let value = try? JSONDecoder().decode(AnyCodableValue.self, from: data) else {
            return nil
        }
        return value
    }
}
