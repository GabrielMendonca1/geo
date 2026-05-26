import Foundation

struct AIWorkflowDefinition: Codable, Hashable {
    var path: String
    var config: AIConfig
    var promptTemplate: String
    var parseError: String?
    var loadedAt: Date
    var loadedFrom: AIWorkflowSource = .json

    var isValidForDispatch: Bool {
        parseError == nil && config.dispatchValidationError == nil
    }
}

enum AIWorkflowSource: String, Codable, Hashable {
    case workflowMarkdown
    case json
}

struct AIConfig: Codable, Hashable {
    var tracker: AITrackerConfig
    var polling: AIPollingConfig
    var workspace: AIWorkspaceConfig
    var hooks: AIHooksConfig
    var agent: AIAgentConfig
    var pi: AIPiWorkflowConfig = AIPiWorkflowConfig()

    static func defaults(workflowDirectory: URL) -> AIConfig {
        AIConfig(
            tracker: .init(),
            polling: .init(),
            workspace: .init(root: workflowDirectory.appendingPathComponent("workspaces", isDirectory: true).path),
            hooks: .init(),
            agent: .init(),
            pi: .init()
        )
    }

    var dispatchValidationError: String? {
        let kind = tracker.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty else { return "tracker.kind is required in WORKFLOW.md." }
        guard kind == "linear" || kind == "local" else { return "Unsupported tracker.kind: \(kind)." }
        if kind == "linear" {
            guard tracker.resolvedAPIKey?.isEmpty == false else {
                return "Linear auth is missing. Set tracker.api_key or LINEAR_API_KEY."
            }
            guard tracker.projectSlug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return "tracker.project_slug is required for Linear."
            }
        }
        return nil
    }
}

struct AITrackerConfig: Codable, Hashable {
    var kind: String = "local"
    var endpoint: String = "https://api.linear.app/graphql"
    var apiKey: String?
    var projectSlug: String?
    var activeStates: [String] = ["Todo", "In Progress"]
    var terminalStates: [String] = ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

    var resolvedAPIKey: String? {
        guard let apiKey, !apiKey.isEmpty else {
            return ProcessInfo.processInfo.environment["LINEAR_API_KEY"]
        }
        if apiKey.hasPrefix("$") {
            let key = String(apiKey.dropFirst())
            return ProcessInfo.processInfo.environment[key]
        }
        return apiKey
    }
}

struct AIPollingConfig: Codable, Hashable {
    var intervalMS: Int = 30_000
}

struct AIWorkspaceConfig: Codable, Hashable {
    var root: String
}

struct AIHooksConfig: Codable, Hashable {
    var afterCreate: String?
    var beforeRun: String?
    var afterRun: String?
    var beforeRemove: String?
    var timeoutMS: Int = 60_000
}

struct AIAgentConfig: Codable, Hashable {
    var maxConcurrentAgents: Int = 4
    var maxTurns: Int = 20
    var maxRetryBackoffMS: Int = 300_000
    var maxConcurrentAgentsByState: [String: Int] = [:]
}

struct AIPiWorkflowConfig: Codable, Hashable {
    var model: String?
    var effort: String?
    var turnTimeoutMS: Int = 3_600_000
    var stallTimeoutMS: Int = 300_000
}

struct AIAgentRuntime: Codable, Hashable, Identifiable {
    var kind: AIAgentKind
    var executablePath: String?
    var version: String?
    var isAvailable: Bool
    var statusDetail: String?

    var id: String { kind.rawValue }
}

struct AIDiscoveredProject: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var rootPath: String
    var gitRootPath: String?
    var gitRemote: String?
    var currentBranch: String?
    var primaryLanguage: String?
    var markerSummary: String
    var buildCommand: String?
    var testCommand: String?
    var trustedForAutomation: Bool
    var enabledAgents: [AIAgentKind]
    var lastScannedAt: Date

    func isAgentEnabled(_ agent: AIAgentKind) -> Bool {
        enabledAgents.contains(agent)
    }
}

struct AIWorkspace: Codable, Hashable, Identifiable {
    var issueID: String
    var issueIdentifier: String
    var workspaceKey: String
    var path: String
    var createdAt: Date
    var lastPreparedAt: Date
    var projectID: String?
    var projectName: String?
    var projectRootPath: String?
    var agent: AIAgentKind = .pi

    var id: String {
        [issueID, projectID ?? "default", agent.rawValue].joined(separator: "::")
    }
}
