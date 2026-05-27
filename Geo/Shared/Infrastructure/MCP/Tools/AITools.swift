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
            "kind": .string(draft.body.kind.rawValue),
            "priority": .string(draft.priority.rawValue),
            "notes": .string(draft.notes),
            "source": .string(parsed.source.rawValue)
        ]

        switch draft.body {
        case .task(let due, let est):
            payload["due"] = .string(formatter.string(from: due))
            if let est { payload["estimated_minutes"] = .int(est) }
        case .event(let start, let end):
            payload["start"] = .string(formatter.string(from: start))
            payload["end"] = .string(formatter.string(from: end))
        case .habit(let rule, let timeOfDay, _):
            payload["recurrence"] = .string(rule.type.rawValue)
            payload["time_of_day"] = .string(formatter.string(from: timeOfDay))
        case .milestone(let target):
            payload["target"] = .string(formatter.string(from: target))
        }

        if !draft.tagIds.isEmpty {
            payload["tag_ids"] = .array(draft.tagIds.map { .string($0) })
        }

        return payload
    }
}
