import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "AITaskParser")

struct AIParsedDraft: Sendable {
    enum Source: String, Sendable {
        case local
        case ai
    }

    let draft: TaskDraft
    let source: Source
}

enum AITaskParser {
    static func parse(_ input: String, now: Date = Date()) async throws -> AIParsedDraft {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = QuickAddParser.parse(trimmed, now: now)

        if parsed.confidence != .low {
            let draft = localDraft(from: parsed, rawInput: trimmed, now: now)
            return AIParsedDraft(draft: draft, source: .local)
        }

        do {
            let iso = isoFormatter.string(from: now)
            let aiResult = try await AnthropicClient.parseTask(input: trimmed, nowISO: iso)
            let draft = await aiDraft(from: aiResult, rawInput: trimmed, fallback: parsed, now: now)
            return AIParsedDraft(draft: draft, source: .ai)
        } catch AnthropicClientError.missingAPIKey {
            let draft = localDraft(from: parsed, rawInput: trimmed, now: now)
            return AIParsedDraft(draft: draft, source: .local)
        } catch AnthropicClientError.truncated {
            logger.warning("AITaskParser fell back to local: truncated")
            let draft = localDraft(from: parsed, rawInput: trimmed, now: now)
            return AIParsedDraft(draft: draft, source: .local)
        } catch let AnthropicClientError.parseFailure(reason) {
            logger.warning("AITaskParser fell back to local: parseFailure \(reason, privacy: .public)")
            let draft = localDraft(from: parsed, rawInput: trimmed, now: now)
            return AIParsedDraft(draft: draft, source: .local)
        }
    }

    private static var isoFormatter: ISO8601DateFormatter { DateFormatters.iso8601Internet }

    private static func localDraft(from parsed: ParsedQuickAdd, rawInput: String, now: Date) -> TaskDraft {
        let title: String = {
            let candidate = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if parsed.confidence == .low || candidate.isEmpty {
                return rawInput
            }
            return candidate
        }()

        let body: TaskBody = parsed.confidence == .low
            ? .task(due: Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now, estimatedMinutes: nil)
            : parsed.body

        return TaskDraft(title: title, body: body)
    }

    private static func aiDraft(
        from json: ParsedTaskJSON,
        rawInput: String,
        fallback: ParsedQuickAdd,
        now: Date
    ) async -> TaskDraft {
        let title: String = {
            let candidate = json.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? rawInput : candidate
        }()

        let kind = TaskKind(rawValue: json.kind.lowercased()) ?? .task
        let priority = TaskPriority(rawValue: (json.priority ?? "unset").lowercased()) ?? .unset

        let startTime = parseISODate(json.start_time_iso) ?? now
        let endTime = parseISODate(json.end_time_iso)
        let notes = json.notes ?? ""
        let tagIds = await resolveTagIds(names: json.tag_names ?? [])

        let body: TaskBody = {
            switch kind {
            case .event:
                let end = endTime ?? startTime.addingTimeInterval(3600)
                return .event(start: startTime, end: end)
            case .habit:
                return .habit(rule: .daily, timeOfDay: startTime, occurrences: [])
            case .milestone:
                return .milestone(target: Calendar.current.startOfDay(for: startTime))
            case .task:
                return .task(due: startTime, estimatedMinutes: nil)
            }
        }()

        return TaskDraft(title: title, notes: notes, priority: priority, tagIds: tagIds, body: body)
    }

    private static func parseISODate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = DateFormatters.iso8601WithFractional.date(from: string) { return date }
        return DateFormatters.iso8601Internet.date(from: string)
    }

    @MainActor
    private static func resolveTagIds(names: [String]) -> [String] {
        guard !names.isEmpty else { return [] }
        let tags = AppContainer.live.tagStore.tags
        var resolved: [String] = []
        for raw in names {
            let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { continue }
            if let match = tags.first(where: { $0.name.lowercased() == needle }) {
                resolved.append(match.id)
            }
        }
        return resolved
    }
}
