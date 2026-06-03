import Foundation

enum TagTools {
    private static let validIdCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    private static func validateBlockId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 256 else { return false }
        if id.contains("/") || id.contains("\\") || id.contains("..") || id.contains("\0") {
            return false
        }
        return id.unicodeScalars.allSatisfy { validIdCharacters.contains($0) }
    }

    static func register(tags: any TagsRepository, blocks: any BlocksRepository) -> [MCPRegisteredTool] {
        [listTags(tags), createTag(tags), setBlockTag(tags, blocks)]
    }

    private static func listTags(_ tags: any TagsRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_tags",
            description: "List all tags with their IDs and colors.",
            schema: JSONSchemaObject(),
            handler: { _ in
                switch AgentAuthorization.authorize(.read, on: nil, layer: nil) {
                case .allow: break
                case .deny(let reason): return .error(reason)
                }
                let allTags = try await tags.list()
                let result = allTags.map { tag -> [String: AnyCodableValue] in
                    [
                        "id": .string(tag.id),
                        "name": .string(tag.name),
                    ]
                }
                return .json(result)
            }
        ).registered
    }

    private static func createTag(_ tags: any TagsRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "create_tag",
            description: "Create a new tag.",
            schema: JSONSchemaObject(properties: [
                "name": .string("Tag name"),
                "color": .object("RGB color (0.0-1.0)", properties: [
                    "red": .number(),
                    "green": .number(),
                    "blue": .number(),
                ]),
            ], required: ["name"]),
            handler: { args in
                guard let name = args["name"]?.stringValue else {
                    return .error("Missing required parameter: name")
                }
                let color: TagColor
                if let colorObj = args["color"]?.objectValue {
                    color = TagColor(
                        red: colorObj["red"]?.doubleValue ?? 0.3,
                        green: colorObj["green"]?.doubleValue ?? 0.5,
                        blue: colorObj["blue"]?.doubleValue ?? 0.9
                    )
                } else {
                    color = TagColor(red: 0.3, green: 0.5, blue: 0.9)
                }
                let tag = try await tags.create(name: name, color: color)
                return .json(["id": tag.id, "name": tag.name])
            }
        ).registered
    }

    private static func setBlockTag(_ tags: any TagsRepository, _ blocks: any BlocksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "set_block_tag",
            description: "Set or change a block's tag by tag name.",
            schema: JSONSchemaObject(properties: [
                "block_id": .string("Block ID (filename)"),
                "tag_name": .string("Tag name to assign (use empty string to clear)"),
            ], required: ["block_id", "tag_name"]),
            handler: { args in
                guard let blockId = args["block_id"]?.stringValue,
                      let tagName = args["tag_name"]?.stringValue else {
                    return .error("Missing required parameters: block_id, tag_name")
                }
                guard validateBlockId(blockId) else {
                    return .error("invalid block id")
                }
                switch try await AgentAuthorization.authorizeWrite(.setTag, id: blockId, in: blocks) {
                case .ok: break
                case .denied(let result): return result
                }

                if tagName.isEmpty {
                    try await blocks.setTag(blockId: blockId, tagId: nil)
                } else {
                    let allTags = try await tags.list()
                    guard let tag = allTags.first(where: { $0.name.caseInsensitiveCompare(tagName) == .orderedSame }) else {
                        return .error("Tag not found: \(tagName)")
                    }
                    try await blocks.setTag(blockId: blockId, tagId: tag.id)
                }
                return .json(["success": true])
            }
        ).registered
    }
}
