import Foundation

enum TagTools {
    static func register(tags: any TagsRepository, blocks: any BlocksRepository) -> [MCPRegisteredTool] {
        [listTags(tags), createTag(tags)]
    }

    private static func listTags(_ tags: any TagsRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_tags",
            description: "List all tags with their IDs and colors.",
            schema: JSONSchemaObject(),
            handler: { _ in
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
}
