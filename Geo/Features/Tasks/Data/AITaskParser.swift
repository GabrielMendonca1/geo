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

        let kind: TaskKind = parsed.confidence == .low ? .task : parsed.kind
        let scheduleFields = scheduleFields(from: parsed.schedule, now: now)

        return TaskDraft(
            title: title,
            startTime: scheduleFields.startTime,
            endTime: scheduleFields.endTime,
            recurrence: scheduleFields.recurrence,
            kind: kind
        )
    }

    private struct ScheduleFields {
        var startTime: Date
        var endTime: Date?
        var recurrence: RecurrenceRule
    }

    private static func scheduleFields(from schedule: Schedule, now: Date) -> ScheduleFields {
        switch schedule {
        case .anytime:
            return ScheduleFields(startTime: now, endTime: nil, recurrence: .never)
        case .dueBy(let date):
            return ScheduleFields(startTime: date, endTime: nil, recurrence: .never)
        case .at(let date, let duration):
            let end = duration.map { date.addingTimeInterval($0) }
            return ScheduleFields(startTime: date, endTime: end, recurrence: .never)
        case .recurring(let rule, let timeOfDay):
            let cal = Calendar.current
            let comps = cal.dateComponents([.hour, .minute], from: timeOfDay)
            let start = cal.date(bySettingHour: comps.hour ?? 9, minute: comps.minute ?? 0, second: 0, of: now) ?? now
            return ScheduleFields(startTime: start, endTime: nil, recurrence: rule)
        case .targeting(let date):
            return ScheduleFields(startTime: date, endTime: nil, recurrence: .never)
        }
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

        return TaskDraft(
            title: title,
            notes: notes,
            startTime: startTime,
            endTime: endTime,
            kind: kind,
            priority: priority,
            tagIds: tagIds
        )
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
