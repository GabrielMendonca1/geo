import Combine
import Foundation

@MainActor
final class HealthViewModel: ObservableObject {
    @Published private(set) var vitalsProtocol: VitalsProtocol?
    @Published private(set) var state: VitalsState?
    @Published private(set) var logs: [VitalsLog] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?

    private let repository: BridgeVitalsRepository

    init(repository: BridgeVitalsRepository = BridgeVitalsRepository()) {
        self.repository = repository
    }

    var sessions: [VitalsSession] {
        vitalsProtocol?.sessions ?? []
    }

    var needsOnboarding: Bool {
        hasLoaded && errorMessage == nil && state == nil && !sessions.isEmpty
    }

    var todayIndex: Int? {
        guard let state, !sessions.isEmpty else { return nil }
        guard let anchor = BridgeVitalsRepository.dayFormatter.date(from: state.anchorDate) else { return nil }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: anchor),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        let count = sessions.count
        return ((state.anchorIndex + days) % count + count) % count
    }

    var todaySession: VitalsSession? {
        guard let todayIndex else { return nil }
        return sessions.first { $0.index == todayIndex } ?? sessions[safe: todayIndex]
    }

    var highlightedMuscles: Set<String> {
        guard let session = todaySession, !session.rest else { return [] }
        return Set(session.muscles + session.exercises.flatMap(\.muscles))
    }

    func reload() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            vitalsProtocol = try await repository.fetchProtocol()
            state = try await repository.fetchState()
            logs = try await repository.fetchLogs().sorted { $0.date > $1.date }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func anchor(to index: Int) async {
        guard let vitalsProtocol else { return }
        let next = VitalsState(
            protocolId: vitalsProtocol.id,
            anchorDate: BridgeVitalsRepository.dayFormatter.string(from: Date()),
            anchorIndex: index
        )
        do {
            try await repository.saveState(next)
            state = next
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var todayLog: VitalsLog? {
        let today = BridgeVitalsRepository.dayFormatter.string(from: Date())
        return logs.first { $0.date == today }
    }

    var todayNote: String {
        todayLog?.note ?? ""
    }

    func todayEntry(for exerciseId: String) -> VitalsLogExercise? {
        todayLog?.exercises.first { $0.id == exerciseId }
    }

    func submit(log: VitalsLog) async throws {
        try await repository.saveLog(log)
        await reload()
    }

    func saveExercise(sessionIndex: Int, exerciseId: String, sets: [VitalsLogSet]) async throws {
        let log = Self.merged(
            existing: todayLog,
            date: BridgeVitalsRepository.dayFormatter.string(from: Date()),
            sessionIndex: sessionIndex,
            exerciseId: exerciseId,
            sets: sets
        )
        try await submit(log: log)
    }

    func saveNote(sessionIndex: Int, note: String) async throws {
        let log = Self.merged(
            existing: todayLog,
            date: BridgeVitalsRepository.dayFormatter.string(from: Date()),
            sessionIndex: sessionIndex,
            note: note
        )
        try await submit(log: log)
    }

    nonisolated static func merged(
        existing: VitalsLog?,
        date: String,
        sessionIndex: Int,
        exerciseId: String,
        sets: [VitalsLogSet]
    ) -> VitalsLog {
        var exercises = existing?.exercises ?? []
        let entry = VitalsLogExercise(id: exerciseId, sets: sets)
        if let index = exercises.firstIndex(where: { $0.id == exerciseId }) {
            if sets.isEmpty {
                exercises.remove(at: index)
            } else {
                exercises[index] = entry
            }
        } else if !sets.isEmpty {
            exercises.append(entry)
        }
        return VitalsLog(
            id: existing?.id ?? UUID().uuidString,
            date: existing?.date ?? date,
            sessionIndex: sessionIndex,
            exercises: exercises,
            note: existing?.note ?? ""
        )
    }

    nonisolated static func merged(
        existing: VitalsLog?,
        date: String,
        sessionIndex: Int,
        note: String
    ) -> VitalsLog {
        VitalsLog(
            id: existing?.id ?? UUID().uuidString,
            date: existing?.date ?? date,
            sessionIndex: sessionIndex,
            exercises: existing?.exercises ?? [],
            note: note
        )
    }

    func lastWeight(for exerciseId: String) -> Double? {
        for log in logs {
            if let entry = log.exercises.first(where: { $0.id == exerciseId }), let last = entry.sets.last {
                return last.kg
            }
        }
        return nil
    }

    func shouldIncreaseLoad(_ exercise: VitalsExercise) -> Bool {
        guard !exercise.sets.isEmpty else { return false }
        let recent = logs.compactMap { log in
            log.exercises.first { $0.id == exercise.id }
        }.prefix(2)
        guard recent.count == 2 else { return false }
        return recent.allSatisfy { entry in
            guard entry.sets.count >= exercise.sets.count else { return false }
            return exercise.sets.indices.allSatisfy { index in
                guard let top = exercise.sets[index].last else { return false }
                return entry.sets[index].reps >= top
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
