import Foundation

struct TrainingClock: Sendable {
    private let calendar: Calendar

    init(timeZone: TimeZone = .autoupdatingCurrent) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    func keys(for date: Date) -> (week: String, day: String) {
        (weekKey(for: date), dayKey(for: date))
    }

    func weekKey(for date: Date) -> String {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", components.yearForWeekOfYear ?? 0, components.weekOfYear ?? 0)
    }

    func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func date(forDayKey value: String) -> Date? {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              dayKey(for: date) == value else { return nil }
        return date
    }

    func days(from startDay: String, to date: Date) -> Int? {
        guard let start = self.date(forDayKey: startDay) else { return nil }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: date)
        ).day
    }

    func dayKeys(forWeek week: String) -> [String]? {
        let parts = week.split(separator: "-")
        guard parts.count == 2,
              parts[1].first == "W",
              let year = Int(parts[0]),
              let number = Int(parts[1].dropFirst()) else { return nil }
        var components = DateComponents()
        components.weekday = 2
        components.weekOfYear = number
        components.yearForWeekOfYear = year
        guard let monday = calendar.date(from: components), weekKey(for: monday) == week else { return nil }
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: monday).map { dayKey(for: $0) }
        }
    }
}

private enum TrainingDecode {
    static func stableID<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> String {
        let value = try container.decode(String.self, forKey: key)
        let range = value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression)
        guard !value.isEmpty, value != ".", value != "..", range == value.startIndex..<value.endIndex else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "invalid stable id")
        }
        return value
    }

    static func validate(sets: [[Int]], codingPath: [any CodingKey]) throws {
        guard sets.allSatisfy({ range in
            range.count == 2 && range[0] > 0 && range[0] <= range[1]
        }) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: codingPath, debugDescription: "invalid set ranges")
            )
        }
    }
}

enum TrainingExerciseStatus: String, Codable, Sendable {
    case active
    case retired
}

struct TrainingCatalogExercise: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let status: TrainingExerciseStatus
    let muscles: [String]
    let equipment: String
    let tags: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, status, muscles, equipment, tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try TrainingDecode.stableID(container, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(TrainingExerciseStatus.self, forKey: .status)
        muscles = try container.decode([String].self, forKey: .muscles)
        equipment = try container.decode(String.self, forKey: .equipment)
        tags = try container.decode([String].self, forKey: .tags)
    }
}

struct TrainingCatalog: Codable, Identifiable, Sendable {
    let schema: String
    let id: String
    let version: Int
    let updatedAt: String
    let exercises: [TrainingCatalogExercise]

    private enum CodingKeys: String, CodingKey {
        case schema, id, version, updatedAt, exercises
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        guard schema == "vitals.catalog/1" else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: container, debugDescription: "unsupported catalog schema")
        }
        id = try TrainingDecode.stableID(container, forKey: .id)
        version = try container.decode(Int.self, forKey: .version)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        exercises = try container.decode([TrainingCatalogExercise].self, forKey: .exercises)
        guard version > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "invalid catalog version")
        }
    }
}

struct TrainingBlockItem: Codable, Sendable {
    let exerciseId: String
    let sets: [[Int]]
    let restSec: Int

    private enum CodingKeys: String, CodingKey {
        case exerciseId, sets, restSec
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exerciseId = try TrainingDecode.stableID(container, forKey: .exerciseId)
        sets = try container.decode([[Int]].self, forKey: .sets)
        restSec = try container.decode(Int.self, forKey: .restSec)
        try TrainingDecode.validate(sets: sets, codingPath: decoder.codingPath)
        guard restSec >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .restSec, in: container, debugDescription: "invalid rest")
        }
    }
}

struct TrainingBlock: Codable, Identifiable, Sendable {
    let id: String
    let version: Int
    let name: String
    let items: [TrainingBlockItem]

    private enum CodingKeys: String, CodingKey {
        case id, version, name, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try TrainingDecode.stableID(container, forKey: .id)
        version = try container.decode(Int.self, forKey: .version)
        name = try container.decode(String.self, forKey: .name)
        items = try container.decode([TrainingBlockItem].self, forKey: .items)
        guard version > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "invalid block version")
        }
    }
}

struct TrainingBlocks: Codable, Sendable {
    let schema: String
    let version: Int
    let blocks: [TrainingBlock]

    private enum CodingKeys: String, CodingKey {
        case schema, version, blocks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        guard schema == "vitals.blocks/1" else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: container, debugDescription: "unsupported blocks schema")
        }
        version = try container.decode(Int.self, forKey: .version)
        blocks = try container.decode([TrainingBlock].self, forKey: .blocks)
        guard version > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "invalid blocks version")
        }
    }
}

struct WeeklyPlanBlockSource: Codable, Sendable {
    let blockId: String
    let blockVersion: Int

    private enum CodingKeys: String, CodingKey {
        case blockId, blockVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockId = try TrainingDecode.stableID(container, forKey: .blockId)
        blockVersion = try container.decode(Int.self, forKey: .blockVersion)
        guard blockVersion > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .blockVersion, in: container, debugDescription: "invalid block version")
        }
    }
}

enum WeeklyPlanGenerator: String, Codable, Sendable {
    case manual
    case conversation
}

struct WeeklyPlanSource: Codable, Sendable {
    let catalogId: String
    let catalogVersion: Int
    let blocks: [WeeklyPlanBlockSource]
    let generator: WeeklyPlanGenerator

    private enum CodingKeys: String, CodingKey {
        case catalogId, catalogVersion, blocks, generator
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        catalogId = try TrainingDecode.stableID(container, forKey: .catalogId)
        catalogVersion = try container.decode(Int.self, forKey: .catalogVersion)
        blocks = try container.decode([WeeklyPlanBlockSource].self, forKey: .blocks)
        generator = try container.decode(WeeklyPlanGenerator.self, forKey: .generator)
        guard catalogVersion > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .catalogVersion, in: container, debugDescription: "invalid catalog version")
        }
    }
}

struct WeeklyPlanItem: Codable, Identifiable, Sendable {
    let exerciseId: String
    let name: String
    let muscles: [String]
    let sets: [[Int]]
    let restSec: Int

    var id: String { exerciseId }

    var vitalsExercise: VitalsExercise {
        VitalsExercise(
            id: exerciseId,
            name: name,
            sets: sets,
            muscles: muscles,
            restSec: restSec
        )
    }

    private enum CodingKeys: String, CodingKey {
        case exerciseId, name, muscles, sets, restSec
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exerciseId = try TrainingDecode.stableID(container, forKey: .exerciseId)
        name = try container.decode(String.self, forKey: .name)
        muscles = try container.decode([String].self, forKey: .muscles)
        sets = try container.decode([[Int]].self, forKey: .sets)
        restSec = try container.decode(Int.self, forKey: .restSec)
        try TrainingDecode.validate(sets: sets, codingPath: decoder.codingPath)
        guard restSec >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .restSec, in: container, debugDescription: "invalid rest")
        }
    }
}

struct WeeklyPlanDay: Codable, Identifiable, Sendable {
    let date: String
    let label: String
    let rest: Bool
    let items: [WeeklyPlanItem]

    var id: String { date }
}

struct WeeklyPlan: Codable, Identifiable, Sendable {
    let schema: String
    let id: String
    let week: String
    let revision: Int
    let frozenAt: String
    let source: WeeklyPlanSource
    let days: [WeeklyPlanDay]

    private enum CodingKeys: String, CodingKey {
        case schema, id, week, revision, frozenAt, source, days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        guard schema == "vitals.plan/1" else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: container, debugDescription: "unsupported plan schema")
        }
        id = try TrainingDecode.stableID(container, forKey: .id)
        week = try container.decode(String.self, forKey: .week)
        revision = try container.decode(Int.self, forKey: .revision)
        frozenAt = try container.decode(String.self, forKey: .frozenAt)
        source = try container.decode(WeeklyPlanSource.self, forKey: .source)
        days = try container.decode([WeeklyPlanDay].self, forKey: .days)
        let clock = TrainingClock(timeZone: TimeZone(secondsFromGMT: 0)!)
        guard revision > 0,
              id == "plan-\(week).r\(revision)",
              let expectedDays = clock.dayKeys(forWeek: week),
              days.map(\.date) == expectedDays else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "invalid frozen plan identity or shape")
        }
    }
}

struct BridgeTrainingRepository: Sendable {
    let client: any BridgeAPI

    init(client: any BridgeAPI = BridgeClient.shared) {
        self.client = client
    }

    func fetchCatalog() async throws -> TrainingCatalog? {
        try await fetchOptional(TrainingCatalog.self, path: BridgeEndpoint.vitalsCatalog.path)
    }

    func fetchBlocks() async throws -> TrainingBlocks? {
        try await fetchOptional(TrainingBlocks.self, path: BridgeEndpoint.vitalsBlocks.path)
    }

    func fetchPlan(week: String) async throws -> WeeklyPlan? {
        guard let plan = try await fetchOptional(WeeklyPlan.self, path: BridgeEndpoint.vitalsPlan(week: week).path) else {
            return nil
        }
        return plan.week == week ? plan : nil
    }

    static func isoWeek(for date: Date, calendar: Calendar = Calendar(identifier: .iso8601)) -> String {
        TrainingClock(calendar: calendar).weekKey(for: date)
    }

    private func fetchOptional<T: Decodable>(_ type: T.Type, path: String) async throws -> T? {
        do {
            let data = try await client.getData(path)
            return try JSONDecoder().decode(type, from: data)
        } catch BridgeError.server(let status, _) where status == 404 {
            return nil
        }
    }
}
