import Foundation

struct DispatchItem: Identifiable, Decodable, Hashable {
    let id: String
    let meta: DispatchMeta
    let status: String

    var isRunning: Bool { status == "running" }
}

struct DispatchMeta: Decodable, Hashable {
    let id: String
    let title: String
    let dir: String?
    let model: String?
    let prompt: String?
    let startedAt: Double?

    private enum CodingKeys: String, CodingKey {
        case id, title, dir, model, prompt
        case startedAt = "started_at"
    }

    var startedDate: Date? {
        startedAt.map { Date(timeIntervalSince1970: $0) }
    }
}

struct StreamDone: Decodable {
    let status: String
}

enum LogJSONValue: Decodable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case array([LogJSONValue])
    case object([String: LogJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([LogJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: LogJSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

struct DispatchLogEvent: Decodable {
    struct Message: Decodable {
        let content: [Block]?
    }

    struct Block: Decodable {
        let type: String
        let text: String?
        let name: String?
        let input: [String: LogJSONValue]?

        var toolLine: String {
            let name = name ?? "tool"
            let preferred = ["description", "command", "file_path", "path", "pattern", "prompt", "query", "url", "skill"]
            let summary = preferred.lazy.compactMap { self.input?[$0]?.stringValue }.first
                ?? input?.values.lazy.compactMap(\.stringValue).first
            guard var summary, !summary.isEmpty else { return name }
            summary = summary.replacingOccurrences(of: "\n", with: " ")
            if summary.count > 120 {
                summary = String(summary.prefix(120)) + "…"
            }
            return "\(name) · \(summary)"
        }
    }

    let type: String
    let subtype: String?
    let message: Message?
    let result: String?
    let isError: Bool?
    let numTurns: Int?
    let durationMs: Double?
    let totalCostUsd: Double?

    private enum CodingKeys: String, CodingKey {
        case type, subtype, message, result
        case isError = "is_error"
        case numTurns = "num_turns"
        case durationMs = "duration_ms"
        case totalCostUsd = "total_cost_usd"
    }
}

struct AgentEvent: Identifiable {
    enum Kind {
        case assistant, tool, result, raw
    }

    let id: Int
    let kind: Kind
    let text: String
    var detail: String? = nil
    var isError: Bool = false
}

extension AgentEvent {
    static func events(fromLogLine line: String, nextID: inout Int) -> [AgentEvent] {
        var made: [AgentEvent] = []
        func add(_ kind: Kind, _ text: String, detail: String? = nil, isError: Bool = false) {
            made.append(AgentEvent(id: nextID, kind: kind, text: text, detail: detail, isError: isError))
            nextID += 1
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return made }
        guard let data = trimmed.data(using: .utf8),
              let event = try? JSONDecoder().decode(DispatchLogEvent.self, from: data) else {
            add(.raw, trimmed)
            return made
        }
        switch event.type {
        case "assistant":
            for block in event.message?.content ?? [] {
                if block.type == "text",
                   let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    add(.assistant, text)
                } else if block.type == "tool_use" {
                    add(.tool, block.toolLine)
                }
            }
        case "result":
            var parts = [event.subtype ?? "result"]
            if let turns = event.numTurns { parts.append("\(turns) turns") }
            if let ms = event.durationMs { parts.append("\(Int(ms / 1000))s") }
            if let cost = event.totalCostUsd { parts.append(String(format: "$%.2f", cost)) }
            add(.result, event.result ?? "", detail: parts.joined(separator: " · "), isError: event.isError ?? false)
        default:
            break
        }
        return made
    }
}
