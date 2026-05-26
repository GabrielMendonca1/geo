import Foundation

enum AgentDispatchTools {
    static func register(ai: any AIRepository) -> [MCPRegisteredTool] {
        [dispatchAgent(ai)]
    }

    private static func dispatchAgent(_ ai: any AIRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "ai_dispatch_agent",
            description: "Spin up a sub-agent in a per-issue workspace under ~/.symphony/workspaces/. Creates an AI issue from title + description, then dispatches it to the configured agent runtime (pi). Optionally targets a discovered project by ID.",
            schema: JSONSchemaObject(
                properties: [
                    "title": .string("Short task title (imperative, e.g. 'Add search bar to Blocks pane')"),
                    "description": .string("Free-form task description with any context, constraints, or files of interest."),
                    "project_id": .string("Optional: discovered project ID to scope the dispatch to. Defaults to currently selected project."),
                ],
                required: ["title"]
            ),
            handler: { args in
                guard let title = args["title"]?.stringValue,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .error("Missing required parameter: title")
                }
                let description = args["description"]?.stringValue ?? ""
                let projectId = args["project_id"]?.stringValue

                let snapshot = await ai.dispatchTask(title: title, description: description, projectID: projectId)

                let issue = snapshot.issues.first(where: { $0.title == title })
                var payload: [String: AnyCodableValue] = [
                    "status": .string("dispatched"),
                    "title": .string(title),
                ]
                if let issue {
                    payload["issue_id"] = .string(issue.id)
                    payload["state"] = .string(issue.state)
                }
                if let selected = snapshot.selectedProjectID {
                    payload["project_id"] = .string(selected)
                }
                if let issueId = issue?.id {
                    let live = snapshot.liveSessions.filter { $0.issueID == issueId }
                    if !live.isEmpty {
                        payload["live_sessions"] = .array(live.map { .string($0.id) })
                    }
                }
                return .json(payload)
            }
        ).registered
    }
}
