import Foundation

struct AIIssue: Codable, Hashable, Identifiable {
    var id: String
    var identifier: String
    var title: String
    var description: String?
    var priority: Int?
    var state: String
    var branchName: String?
    var url: String?
    var labels: [String]
    var blockedBy: [AIBlocker]
    var createdAt: Date?
    var updatedAt: Date?
    var linkedBlockID: String?
    var symphonyAgent: String?
    var symphonyModel: String?
    var symphonyEffort: String?
    var symphonySessionID: String?

    init(
        id: String,
        identifier: String,
        title: String,
        description: String? = nil,
        priority: Int? = nil,
        state: String,
        branchName: String? = nil,
        url: String? = nil,
        labels: [String] = [],
        blockedBy: [AIBlocker] = [],
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        linkedBlockID: String? = nil,
        symphonyAgent: String? = nil,
        symphonyModel: String? = nil,
        symphonyEffort: String? = nil,
        symphonySessionID: String? = nil
    ) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.description = description
        self.priority = priority
        self.state = state
        self.branchName = branchName
        self.url = url
        self.labels = labels
        self.blockedBy = blockedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.linkedBlockID = linkedBlockID
        self.symphonyAgent = symphonyAgent
        self.symphonyModel = symphonyModel
        self.symphonyEffort = symphonyEffort
        self.symphonySessionID = symphonySessionID
    }

    var normalizedState: String {
        state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var prioritySortValue: Int {
        priority ?? Int.max
    }
}

struct AIBlocker: Codable, Hashable, Identifiable {
    var trackerID: String?
    var identifier: String?
    var state: String?
    var createdAt: Date?
    var updatedAt: Date?

    var id: String { trackerID ?? identifier ?? "blocker-\(state ?? "unknown")" }
}

struct AIToolCall: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case read
        case edit
        case run
        case search
        case write
        case other
    }
    var id: UUID
    var kind: Kind
    var name: String
    var target: String?
    var timestamp: Date
}

struct AIRunAttempt: Codable, Hashable, Identifiable {
    var id: UUID
    var issueID: String
    var issueIdentifier: String
    var projectID: String?
    var projectName: String?
    var projectRootPath: String?
    var agent: AIAgentKind
    var attempt: Int
    var workspacePath: String
    var startedAt: Date
    var finishedAt: Date?
    var status: AIRunStatus
    var error: String?
    var toolCalls: [AIToolCall] = []

    init(
        id: UUID = UUID(),
        issueID: String,
        issueIdentifier: String,
        projectID: String? = nil,
        projectName: String? = nil,
        projectRootPath: String? = nil,
        agent: AIAgentKind = .pi,
        attempt: Int,
        workspacePath: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: AIRunStatus,
        error: String? = nil,
        toolCalls: [AIToolCall] = []
    ) {
        self.id = id
        self.issueID = issueID
        self.issueIdentifier = issueIdentifier
        self.projectID = projectID
        self.projectName = projectName
        self.projectRootPath = projectRootPath
        self.agent = agent
        self.attempt = attempt
        self.workspacePath = workspacePath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.error = error
        self.toolCalls = toolCalls
    }
}

struct AILiveSession: Codable, Hashable, Identifiable {
    var issueID: String
    var issueIdentifier: String
    var sessionID: String
    var threadID: String
    var turnID: String
    var processID: String?
    var lastEvent: String?
    var lastTimestamp: Date?
    var lastMessage: String?
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    var turnCount: Int
    var startedAt: Date
    var workspacePath: String
    var projectID: String?
    var projectName: String?
    var projectRootPath: String?
    var agent: AIAgentKind = .pi
    var provider: String?
    var modelLabel: String?
    var recentToolCalls: [AIToolCall] = []
    var piSessionID: String?

    var id: String { sessionID }
}

struct AIRetryEntry: Codable, Hashable, Identifiable {
    var issueID: String
    var identifier: String
    var attempt: Int
    var dueAt: Date
    var error: String?

    var id: String { issueID }
}

struct AIAgentTotals: Codable, Hashable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var totalTokens: Int = 0
    var runtimeSeconds: TimeInterval = 0
}

struct AIOrchestratorState: Codable, Hashable {
    var serviceStatus: AIServiceStatus
    var pollIntervalMS: Int
    var maxConcurrentAgents: Int
    var runningIssueIDs: Set<String>
    var runningSessionIDs: Set<String> = []
    var claimedIssueIDs: Set<String>
    var retryEntries: [AIRetryEntry]
    var completedIssueIDs: Set<String>
    var agentTotals: AIAgentTotals
    var lastPollAt: Date?
}

struct AILogEntry: Codable, Hashable, Identifiable {
    var id: UUID
    var timestamp: Date
    var level: AILogLevel
    var message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), level: AILogLevel, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

struct AISnapshot: Codable, Hashable {
    var workflow: AIWorkflowDefinition
    var state: AIOrchestratorState
    var issues: [AIIssue]
    var workspaces: [AIWorkspace]
    var attempts: [AIRunAttempt]
    var liveSessions: [AILiveSession]
    var logs: [AILogEntry]
    var projects: [AIDiscoveredProject] = []
    var selectedProjectID: String?
    var agentRuntimes: [AIAgentRuntime] = []

    var issuesByState: [String: [AIIssue]] {
        Dictionary(grouping: issues, by: \.state)
    }

    var selectedProject: AIDiscoveredProject? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    var liveSessionsByIssueID: [String: [AILiveSession]] {
        Dictionary(grouping: liveSessions, by: \.issueID)
    }

    var runningCount: Int { liveSessions.count }
}
