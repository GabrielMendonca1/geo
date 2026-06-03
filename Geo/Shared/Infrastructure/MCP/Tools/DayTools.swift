import Foundation

enum DayTools {
    private static let validIdCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    private static func validateBlockId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 256 else { return false }
        if id.contains("/") || id.contains("\\") || id.contains("..") || id.contains("\0") {
            return false
        }
        return id.unicodeScalars.allSatisfy { validIdCharacters.contains($0) }
    }

    static func register(days: any DayRepository, blocks: any BlocksRepository) -> [MCPRegisteredTool] {
        [getToday(days), getDay(days), linkBlockToDay(days, blocks)]
    }

    private static func getToday(_ days: any DayRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "get_today",
            description: "Get today's day record with linked blocks and captures.",
            schema: JSONSchemaObject(),
            handler: { _ in
                let day = await days.day(for: Date())
                guard let day else {
                    return .json(["id": AnyCodableValue.null, "block_ids": AnyCodableValue.array([]), "capture_count": AnyCodableValue.int(0)])
                }
                let result: [String: AnyCodableValue] = [
                    "id": .string(day.id),
                    "block_ids": .array(day.blockIds.map { .string($0) }),
                    "capture_count": .int(day.captureIds.count),
                ]
                return .json(result)
            }
        ).registered
    }

    private static func getDay(_ days: any DayRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "get_day",
            description: "Get a specific day's record.",
            schema: JSONSchemaObject(properties: [
                "date": .string("Date in YYYY-MM-DD format"),
            ], required: ["date"]),
            handler: { args in
                guard let dateStr = args["date"]?.stringValue else {
                    return .error("Missing required parameter: date")
                }
                let formatter = DateFormatters.iso8601FullDate
                guard let date = formatter.date(from: dateStr) else {
                    return .error("Invalid date format. Use YYYY-MM-DD")
                }
                let day = await days.day(for: date)
                guard let day else {
                    let empty: [String: AnyCodableValue] = [
                        "id": .string(dateStr),
                        "block_ids": .array([]),
                        "capture_count": .int(0),
                    ]
                    return .json(empty)
                }
                let result: [String: AnyCodableValue] = [
                    "id": .string(day.id),
                    "block_ids": .array(day.blockIds.map { .string($0) }),
                    "capture_count": .int(day.captureIds.count),
                ]
                return .json(result)
            }
        ).registered
    }

    private static func linkBlockToDay(_ days: any DayRepository, _ blocks: any BlocksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "link_block_to_day",
            description: "Link a block to a specific day.",
            schema: JSONSchemaObject(properties: [
                "block_id": .string("Block ID (filename)"),
                "date": .string("Date in YYYY-MM-DD format"),
            ], required: ["block_id", "date"]),
            handler: { args in
                guard let blockId = args["block_id"]?.stringValue,
                      let dateStr = args["date"]?.stringValue else {
                    return .error("Missing required parameters: block_id, date")
                }
                guard validateBlockId(blockId) else {
                    return .error("invalid block id")
                }
                let formatter = DateFormatters.iso8601FullDate
                guard let date = formatter.date(from: dateStr) else {
                    return .error("Invalid date format. Use YYYY-MM-DD")
                }
                switch try await AgentAuthorization.authorizeWrite(.linkToDay, id: blockId, in: blocks) {
                case .ok: break
                case .denied(let result): return result
                }
                try await days.addBlockToDay(date: date, blockId: blockId)
                return .json(["success": true])
            }
        ).registered
    }
}
