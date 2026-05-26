import Foundation

enum AIKanbanStatus: String, Codable, CaseIterable, Hashable {
    case triage
    case todo
    case ready
    case running
    case blocked
    case done
    case archived

    var label: String {
        switch self {
        case .triage: return "Triage"
        case .todo: return "Todo"
        case .ready: return "Ready"
        case .running: return "Running"
        case .blocked: return "Blocked"
        case .done: return "Done"
        case .archived: return "Archived"
        }
    }

    var isTerminal: Bool { self == .done || self == .archived }

    static func fromIssueState(_ raw: String) -> AIKanbanStatus {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "triage": return .triage
        case "backlog", "todo": return .todo
        case "ready": return .ready
        case "in progress", "in-progress", "in_progress", "running": return .running
        case "blocked", "human review", "human-review", "human_review": return .blocked
        case "done", "merging", "merge", "closed": return .done
        case "archived", "canceled", "cancelled", "duplicate": return .archived
        case "rework": return .ready
        default: return .todo
        }
    }
}

enum AIKanbanOutcome: String, Codable, Hashable {
    case completed
    case blocked
    case crashed
    case timedOut = "timed_out"
    case reclaimed
    case spawnFailed = "spawn_failed"
    case gaveUp = "gave_up"
    case canceled

    var isSuccess: Bool { self == .completed }

    var isFailure: Bool {
        switch self {
        case .crashed, .timedOut, .spawnFailed, .gaveUp:
            return true
        default:
            return false
        }
    }
}

enum AIKanbanEventKind: String, Codable, Hashable {
    case created
    case statusChanged = "status"
    case claimed
    case spawned
    case heartbeat
    case completed
    case blocked
    case unblocked
    case reclaimed
    case crashed
    case timedOut = "timed_out"
    case spawnFailed = "spawn_failed"
    case gaveUp = "gave_up"
    case promoted
    case archived
    case commentAdded = "comment_added"
    case linked
    case unlinked
    case edited
    case heartbeatGap = "heartbeat_gap"
    case handoffApplied = "handoff_applied"
}

struct AIKanbanTask: Codable, Hashable, Identifiable {
    var id: String
    var identifier: String
    var title: String
    var body: String
    var profile: String?
    var status: AIKanbanStatus
    var priority: Int?
    var workspacePath: String?
    var idempotencyKey: String?
    var maxRuntimeSeconds: Int?
    var claimLock: String?
    var claimLockExpiresAt: Date?
    var claimLockRunID: String?
    var board: String
    var tenant: String?
    var linkedBlockID: String?
    var consecutiveFailures: Int
    var createdAt: Date
    var updatedAt: Date
}

struct AIKanbanRun: Codable, Hashable, Identifiable {
    var id: String
    var taskID: String
    var attempt: Int
    var profile: String?
    var agent: String?
    var workspacePath: String?
    var startedAt: Date
    var endedAt: Date?
    var lastHeartbeatAt: Date?
    var outcome: AIKanbanOutcome?
    var summary: String?
    var metadataJSON: String?
    var resultJSON: String?
    var errorMessage: String?
    var pid: Int32?
}

struct AIKanbanLink: Codable, Hashable, Identifiable {
    var parentID: String
    var childID: String

    var id: String { "\(parentID)->\(childID)" }
}

struct AIKanbanComment: Codable, Hashable, Identifiable {
    var id: String
    var taskID: String
    var author: String
    var body: String
    var createdAt: Date
}

struct AIKanbanEvent: Codable, Hashable, Identifiable {
    var id: Int64
    var taskID: String?
    var runID: String?
    var kind: AIKanbanEventKind
    var payloadJSON: String?
    var createdAt: Date
}

struct AIKanbanClaim: Hashable {
    var task: AIKanbanTask
    var runID: String
    var attempt: Int
    var lease: String
    var expiresAt: Date
}

struct AIKanbanHandoff: Codable, Hashable {
    var parentTaskID: String
    var parentIdentifier: String
    var summary: String?
    var metadataJSON: String?
    var resultJSON: String?

    var renderedContext: String {
        var parts: [String] = []
        parts.append("- Parent: \(parentIdentifier)")
        if let summary, !summary.isEmpty {
            parts.append("  Summary: \(summary)")
        }
        if let metadataJSON, !metadataJSON.isEmpty, metadataJSON != "{}" {
            parts.append("  Metadata: \(metadataJSON)")
        }
        if let resultJSON, !resultJSON.isEmpty, resultJSON != "{}" {
            parts.append("  Result: \(resultJSON)")
        }
        return parts.joined(separator: "\n")
    }
}

struct AIKanbanWorkerResult: Codable, Hashable {
    var summary: String?
    var metadata: [String: AIJSONValue]?
    var result: [String: AIJSONValue]?
}

struct AIKanbanWorkerBlock: Codable, Hashable {
    var reason: String
}

enum AIJSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AIJSONValue])
    case object([String: AIJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AIJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AIJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}
