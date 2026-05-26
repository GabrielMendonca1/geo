import Foundation

enum NanoMessageRole: String, Sendable {
    case user
    case assistant
}

struct NanoToolCall: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let input: JSONValue
    var result: JSONValue?
    var isError: Bool = false
    var startedAt: Date = Date()
    var endedAt: Date? = nil

    var elapsedSeconds: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var status: Status {
        if isError { return .failed }
        if result != nil || endedAt != nil { return .done }
        return .running
    }

    enum Status: Sendable, Equatable {
        case running, done, failed
    }

    static func == (lhs: NanoToolCall, rhs: NanoToolCall) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isError == rhs.isError
            && lhs.input == rhs.input
            && lhs.result == rhs.result
            && lhs.endedAt == rhs.endedAt
    }
}

struct NanoMessage: Identifiable, Sendable {
    let id: UUID
    let role: NanoMessageRole
    var text: String
    var toolCalls: [NanoToolCall]
    var isStreaming: Bool
    let ts: Date

    init(id: UUID = UUID(), role: NanoMessageRole, text: String = "", toolCalls: [NanoToolCall] = [], isStreaming: Bool = false, ts: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.isStreaming = isStreaming
        self.ts = ts
    }
}
