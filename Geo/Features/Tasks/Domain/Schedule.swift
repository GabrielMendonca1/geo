import Foundation

enum Schedule: Codable, Hashable {
    case anytime
    case dueBy(Date)
    case at(Date, duration: TimeInterval?)
    case recurring(rule: RecurrenceRule, timeOfDay: Date)
    case targeting(Date)

    private enum CodingKeys: String, CodingKey {
        case type
        case date
        case duration
        case rule
        case timeOfDay
    }

    private enum Kind: String, Codable {
        case anytime
        case dueBy
        case at
        case recurring
        case targeting
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .anytime:
            try container.encode(Kind.anytime, forKey: .type)
        case .dueBy(let date):
            try container.encode(Kind.dueBy, forKey: .type)
            try container.encode(date, forKey: .date)
        case .at(let date, let duration):
            try container.encode(Kind.at, forKey: .type)
            try container.encode(date, forKey: .date)
            try container.encodeIfPresent(duration, forKey: .duration)
        case .recurring(let rule, let timeOfDay):
            try container.encode(Kind.recurring, forKey: .type)
            try container.encode(rule, forKey: .rule)
            try container.encode(timeOfDay, forKey: .timeOfDay)
        case .targeting(let date):
            try container.encode(Kind.targeting, forKey: .type)
            try container.encode(date, forKey: .date)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .anytime:
            self = .anytime
        case .dueBy:
            let date = try container.decode(Date.self, forKey: .date)
            self = .dueBy(date)
        case .at:
            let date = try container.decode(Date.self, forKey: .date)
            let duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
            self = .at(date, duration: duration)
        case .recurring:
            let rule = try container.decode(RecurrenceRule.self, forKey: .rule)
            let timeOfDay = try container.decode(Date.self, forKey: .timeOfDay)
            self = .recurring(rule: rule, timeOfDay: timeOfDay)
        case .targeting:
            let date = try container.decode(Date.self, forKey: .date)
            self = .targeting(date)
        }
    }
}

extension Schedule {
    var anchorDate: Date? {
        switch self {
        case .anytime:
            return nil
        case .dueBy(let date):
            return date
        case .at(let date, _):
            return date
        case .recurring(_, let timeOfDay):
            return timeOfDay
        case .targeting(let date):
            return date
        }
    }

    var endDate: Date? {
        switch self {
        case .anytime, .dueBy:
            return nil
        case .at(let date, let duration):
            guard let duration else { return nil }
            return date.addingTimeInterval(duration)
        case .recurring(let rule, _):
            return rule.endDate
        case .targeting(let date):
            return date
        }
    }

    var isRecurring: Bool {
        if case .recurring = self { return true }
        return false
    }

    var displayLabel: String {
        switch self {
        case .anytime:
            return "Anytime"
        case .dueBy(let date):
            return "Due \(Self.shortFormatter.string(from: date))"
        case .at(let date, let duration):
            if let duration, duration > 0 {
                let end = date.addingTimeInterval(duration)
                return "\(Self.shortFormatter.string(from: date)) – \(Self.timeFormatter.string(from: end))"
            }
            return Self.shortFormatter.string(from: date)
        case .recurring(let rule, let timeOfDay):
            return "\(rule.displayName) at \(Self.timeFormatter.string(from: timeOfDay))"
        case .targeting(let date):
            return "Target \(Self.shortFormatter.string(from: date))"
        }
    }

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static var timeFormatter: DateFormatter { DateFormatters.shortTime }

    static func fromLegacyFields(
        kind: TaskKind,
        startTime: Date,
        endTime: Date?,
        recurrence: RecurrenceRule
    ) -> Schedule {
        switch kind {
        case .milestone:
            return .targeting(startTime)
        case .habit where recurrence.isRepeating:
            return .recurring(rule: recurrence, timeOfDay: startTime)
        case .event:
            let duration = endTime?.timeIntervalSince(startTime)
            return .at(startTime, duration: duration)
        case .task where recurrence == .never && endTime == nil:
            return .dueBy(startTime)
        default:
            if endTime != nil {
                return .at(startTime, duration: endTime?.timeIntervalSince(startTime))
            }
            return .at(startTime, duration: nil)
        }
    }
}
