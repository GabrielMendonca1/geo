import Foundation

enum AITools {
    static func register() -> [MCPRegisteredTool] {
        [parseTask()]
    }

    private static func parseTask() -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "ai_parse_task",
            description: "Parse free-form natural language into a structured task draft. Hybrid: local parser first, Claude Haiku fallback for ambiguous input.",
            schema: JSONSchemaObject(
                properties: [
                    "input": .string("Natural language task description (any language)")
                ],
                required: ["input"]
            ),
            handler: { args in
                guard let input = args["input"]?.stringValue,
                      !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .error("Missing required parameter: input")
                }

                do {
                    let parsed = try await AITaskParser.parse(input)
                    let payload = serialize(parsed)
                    return .json(payload)
                } catch {
                    return .error(error.localizedDescription)
                }
            }
        ).registered
    }

    private static func serialize(_ parsed: AIParsedDraft) -> [String: AnyCodableValue] {
        let draft = parsed.draft
        let formatter = DateFormatters.iso8601

        var payload: [String: AnyCodableValue] = [
            "title": .string(draft.title),
            "kind": .string(draft.kind.rawValue),
            "priority": .string(draft.priority.rawValue),
            "start_time": .string(formatter.string(from: draft.startTime)),
            "end_time": draft.endTime.map { .string(formatter.string(from: $0)) } ?? .null,
            "notes": .string(draft.notes),
            "source": .string(parsed.source.rawValue)
        ]

        if !draft.tagIds.isEmpty {
            payload["tag_ids"] = .array(draft.tagIds.map { .string($0) })
        }
        if draft.recurrence.isRepeating {
            payload["recurrence"] = .string(draft.recurrence.type.rawValue)
        }

        return payload
    }
}
