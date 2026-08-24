import Foundation

struct VitalsExercise: Decodable, Identifiable {
    let id: String
    let name: String
    let sets: [[Int]]
    let muscles: [String]
    let restSec: Int?

    init(id: String, name: String, sets: [[Int]], muscles: [String], restSec: Int? = nil) {
        self.id = id
        self.name = name
        self.sets = sets
        self.muscles = muscles
        self.restSec = restSec
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sets, muscles, restSec
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        sets = try container.decodeIfPresent([[Int]].self, forKey: .sets) ?? []
        muscles = try container.decodeIfPresent([String].self, forKey: .muscles) ?? []
        restSec = try container.decodeIfPresent(Int.self, forKey: .restSec)
    }
}

struct VitalsSession: Decodable, Identifiable {
    let index: Int
    let name: String
    let short: String
    let rest: Bool
    let muscles: [String]
    let exercises: [VitalsExercise]

    var id: Int { index }

    init(index: Int, name: String, short: String, rest: Bool, muscles: [String], exercises: [VitalsExercise]) {
        self.index = index
        self.name = name
        self.short = short
        self.rest = rest
        self.muscles = muscles
        self.exercises = exercises
    }

    private enum CodingKeys: String, CodingKey {
        case index, name, short, rest, muscles, exercises
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        short = try container.decodeIfPresent(String.self, forKey: .short) ?? ""
        rest = try container.decodeIfPresent(Bool.self, forKey: .rest) ?? false
        muscles = try container.decodeIfPresent([String].self, forKey: .muscles) ?? []
        exercises = try container.decodeIfPresent([VitalsExercise].self, forKey: .exercises) ?? []
    }
}

struct VitalsProtocol: Decodable {
    let id: String
    let name: String
    let sessions: [VitalsSession]

    private enum CodingKeys: String, CodingKey {
        case id, name, sessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        sessions = try container.decodeIfPresent([VitalsSession].self, forKey: .sessions) ?? []
    }
}

struct VitalsState: Codable {
    let protocolId: String
    let anchorDate: String
    let anchorIndex: Int

    init(protocolId: String, anchorDate: String, anchorIndex: Int) {
        self.protocolId = protocolId
        self.anchorDate = anchorDate
        self.anchorIndex = anchorIndex
    }

    private enum CodingKeys: String, CodingKey {
        case protocolId, anchorDate, anchorIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolId = try container.decodeIfPresent(String.self, forKey: .protocolId) ?? ""
        anchorDate = try container.decodeIfPresent(String.self, forKey: .anchorDate) ?? ""
        anchorIndex = try container.decodeIfPresent(Int.self, forKey: .anchorIndex) ?? 0
    }
}

struct VitalsLogSet: Codable {
    let reps: Int
    let kg: Double

    init(reps: Int, kg: Double) {
        self.reps = reps
        self.kg = kg
    }

    private enum CodingKeys: String, CodingKey {
        case reps, kg
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reps = try container.decodeIfPresent(Int.self, forKey: .reps) ?? 0
        kg = try container.decodeIfPresent(Double.self, forKey: .kg) ?? 0
    }
}

struct VitalsLogExercise: Codable {
    let id: String
    let sets: [VitalsLogSet]

    init(id: String, sets: [VitalsLogSet]) {
        self.id = id
        self.sets = sets
    }

    private enum CodingKeys: String, CodingKey {
        case id, sets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        sets = try container.decodeIfPresent([VitalsLogSet].self, forKey: .sets) ?? []
    }
}

struct VitalsLog: Codable, Identifiable {
    let id: String
    let date: String
    let sessionIndex: Int?
    let planId: String?
    let planDayId: String?
    let exercises: [VitalsLogExercise]
    let note: String

    init(
        id: String,
        date: String,
        sessionIndex: Int? = nil,
        planId: String? = nil,
        planDayId: String? = nil,
        exercises: [VitalsLogExercise],
        note: String
    ) {
        self.id = id
        self.date = date
        self.sessionIndex = sessionIndex
        self.planId = planId
        self.planDayId = planDayId
        self.exercises = exercises
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, sessionIndex, planId, planDayId, exercises, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        sessionIndex = try container.decodeIfPresent(Int.self, forKey: .sessionIndex)
        planId = try container.decodeIfPresent(String.self, forKey: .planId)
        planDayId = try container.decodeIfPresent(String.self, forKey: .planDayId)
        exercises = try container.decodeIfPresent([VitalsLogExercise].self, forKey: .exercises) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct BridgeVitalsRepository {
    let client: any BridgeAPI

    init(client: any BridgeAPI = BridgeClient.shared) {
        self.client = client
    }

    func fetchProtocol() async throws -> VitalsProtocol {
        let data = try await client.getData(BridgeEndpoint.vitalsProtocol.path)
        return try JSONDecoder().decode(VitalsProtocol.self, from: data)
    }

    func fetchState() async throws -> VitalsState? {
        do {
            let data = try await client.getData(BridgeEndpoint.vitalsState.path)
            if data.isEmpty { return nil }
            return try? JSONDecoder().decode(VitalsState.self, from: data)
        } catch BridgeError.server(let status, _) where status == 404 {
            return nil
        }
    }

    func saveState(_ state: VitalsState) async throws {
        _ = try await client.postData(
            BridgeEndpoint.vitalsState.path,
            body: try JSONEncoder().encode(state),
            token: nil
        )
    }

    func fetchLogs() async throws -> [VitalsLog] {
        do {
            let data = try await client.getData(BridgeEndpoint.vitalsLogs.path)
            if data.isEmpty { return [] }
            return (try? JSONDecoder().decode([VitalsLog].self, from: data)) ?? []
        } catch BridgeError.server(let status, _) where status == 404 {
            return []
        }
    }

    func saveLog(_ log: VitalsLog) async throws {
        _ = try await client.postData(
            BridgeEndpoint.vitalsLog.path,
            body: try JSONEncoder().encode(log),
            token: nil
        )
    }
}
