import Combine
import Foundation

enum VitalsLogIdentity: Equatable {
    case legacy(sessionIndex: Int)
    case plan(planId: String, planDayId: String)
}

enum EffectiveDay {
    case plan(WeeklyPlan, WeeklyPlanDay)
    case legacy(VitalsSession)
}

@MainActor
final class HealthViewModel: ObservableObject {
    @Published private(set) var vitalsProtocol: VitalsProtocol?
    @Published private(set) var state: VitalsState?
    @Published private(set) var logs: [VitalsLog] = []
    @Published private(set) var plan: WeeklyPlan?
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var planErrorMessage: String?

    private let repository: BridgeVitalsRepository
    private let trainingRepository: BridgeTrainingRepository
    private let clock: TrainingClock
    private let now: () -> Date
    private var loadedWeek = ""
    private var loadedDay = ""

    init(
        repository: BridgeVitalsRepository = BridgeVitalsRepository(),
        trainingRepository: BridgeTrainingRepository = BridgeTrainingRepository(),
        clock: TrainingClock = TrainingClock(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.trainingRepository = trainingRepository
        self.clock = clock
        self.now = now
    }

    var sessions: [VitalsSession] {
        vitalsProtocol?.sessions ?? []
    }

    var todayKey: String {
        clock.dayKey(for: now())
    }

    var effectiveDay: EffectiveDay? {
        effectiveDay(for: now())
    }

    private func effectiveDay(for date: Date) -> EffectiveDay? {
        let keys = clock.keys(for: date)
        if let plan, plan.week == keys.week, let day = plan.days.first(where: { $0.date == keys.day }) {
            return .plan(plan, day)
        }
        guard let legacySession = legacySession(for: date) else { return nil }
        return .legacy(legacySession)
    }

    var isPlanPrimary: Bool {
        if case .plan = effectiveDay { return true }
        return false
    }

    var needsOnboarding: Bool {
        hasLoaded && errorMessage == nil && !isPlanPrimary && state == nil && !sessions.isEmpty
    }

    var todayIndex: Int? {
        todayIndex(for: now())
    }

    private func todayIndex(for date: Date) -> Int? {
        let week = clock.weekKey(for: date)
        guard plan?.week != week, let state, !sessions.isEmpty else { return nil }
        guard let days = clock.days(from: state.anchorDate, to: date) else { return nil }
        let count = sessions.count
        return ((state.anchorIndex + days) % count + count) % count
    }

    private func legacySession(for date: Date) -> VitalsSession? {
        guard let index = todayIndex(for: date) else { return nil }
        return sessions.first { $0.index == index } ?? sessions[safe: index]
    }

    var todaySession: VitalsSession? {
        switch effectiveDay {
        case .plan(_, let day):
            let exercises = day.items.map(\.vitalsExercise)
            return VitalsSession(
                index: -1,
                name: day.label,
                short: day.label,
                rest: day.rest,
                muscles: Array(Set(day.items.flatMap(\.muscles))).sorted(),
                exercises: exercises
            )
        case .legacy(let session):
            return session
        case nil:
            return nil
        }
    }

    var highlightedMuscles: Set<String> {
        guard let session = todaySession, !session.rest else { return [] }
        return Set(session.muscles + session.exercises.flatMap(\.muscles))
    }

    func reload(date: Date? = nil) async {
        let date = date ?? now()
        let keys = clock.keys(for: date)
        loadedWeek = keys.week
        loadedDay = keys.day
        let week = keys.week
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        async let planRequest = trainingRepository.fetchPlan(week: week)
        async let protocolRequest = repository.fetchProtocol()
        async let stateRequest = repository.fetchState()
        async let logsRequest = repository.fetchLogs()

        do {
            plan = try await planRequest
            planErrorMessage = nil
        } catch {
            plan = nil
            planErrorMessage = error.localizedDescription
        }

        var legacyError: Error?
        do {
            vitalsProtocol = try await protocolRequest
        } catch {
            vitalsProtocol = nil
            legacyError = error
        }
        do {
            state = try await stateRequest
        } catch {
            state = nil
            legacyError = legacyError ?? error
        }
        do {
            logs = try await logsRequest.sorted { $0.date > $1.date }
        } catch {
            logs = []
            errorMessage = error.localizedDescription
            return
        }

        if plan != nil {
            errorMessage = nil
        } else if let legacyError {
            errorMessage = legacyError.localizedDescription
        } else {
            errorMessage = nil
        }
    }

    func anchor(to index: Int) async {
        guard !isPlanPrimary, let vitalsProtocol else { return }
        let next = VitalsState(
            protocolId: vitalsProtocol.id,
            anchorDate: clock.dayKey(for: now()),
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
        todayLog(for: now())
    }

    private func todayLog(for date: Date) -> VitalsLog? {
        let day = clock.dayKey(for: date)
        return logs.first { $0.date == day }
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

    func saveExercise(exerciseId: String, sets: [VitalsLogSet]) async throws {
        guard let target = await saveTarget() else { return }
        let log = Self.merged(
            existing: target.existing,
            date: target.day,
            identity: target.identity,
            exerciseId: exerciseId,
            sets: sets
        )
        try await submit(log: log)
    }

    func saveNote(note: String) async throws {
        guard let target = await saveTarget() else { return }
        let log = Self.merged(
            existing: target.existing,
            date: target.day,
            identity: target.identity,
            note: note
        )
        try await submit(log: log)
    }

    private func saveTarget() async -> (day: String, identity: VitalsLogIdentity, existing: VitalsLog?)? {
        var date = now()
        var keys = clock.keys(for: date)
        if keys.week != loadedWeek || keys.day != loadedDay {
            await reload(date: date)
            date = now()
            keys = clock.keys(for: date)
        }
        guard keys.week == loadedWeek,
              keys.day == loadedDay,
              let identity = logIdentity(for: date) else { return nil }
        return (keys.day, identity, todayLog(for: date))
    }

    private func logIdentity(for date: Date) -> VitalsLogIdentity? {
        switch effectiveDay(for: date) {
        case .plan(let plan, let day):
            return .plan(planId: plan.id, planDayId: day.id)
        case .legacy(let session):
            return .legacy(sessionIndex: session.index)
        case nil:
            return nil
        }
    }

    nonisolated static func merged(
        existing: VitalsLog?,
        date: String,
        identity: VitalsLogIdentity,
        exerciseId: String,
        sets: [VitalsLogSet]
    ) -> VitalsLog {
        let current = existing?.date == date ? existing : nil
        var exercises = current?.exercises ?? []
        let insertionIndex = exercises.firstIndex(where: { $0.id == exerciseId }) ?? exercises.endIndex
        exercises.removeAll { $0.id == exerciseId }
        if !sets.isEmpty {
            exercises.insert(
                VitalsLogExercise(id: exerciseId, sets: sets),
                at: min(insertionIndex, exercises.endIndex)
            )
        }
        return makeLog(
            current: current,
            date: date,
            identity: identity,
            exercises: exercises,
            note: current?.note ?? ""
        )
    }

    nonisolated static func merged(
        existing: VitalsLog?,
        date: String,
        identity: VitalsLogIdentity,
        note: String
    ) -> VitalsLog {
        let current = existing?.date == date ? existing : nil
        return makeLog(
            current: current,
            date: date,
            identity: identity,
            exercises: current?.exercises ?? [],
            note: note
        )
    }

    nonisolated private static func makeLog(
        current: VitalsLog?,
        date: String,
        identity: VitalsLogIdentity,
        exercises: [VitalsLogExercise],
        note: String
    ) -> VitalsLog {
        switch identity {
        case .legacy(let sessionIndex):
            return VitalsLog(
                id: current?.id ?? UUID().uuidString,
                date: date,
                sessionIndex: sessionIndex,
                exercises: exercises,
                note: note
            )
        case .plan(let planId, let planDayId):
            return VitalsLog(
                id: current?.id ?? UUID().uuidString,
                date: date,
                planId: planId,
                planDayId: planDayId,
                exercises: exercises,
                note: note
            )
        }
    }

    nonisolated static func merged(
        existing: VitalsLog?,
        date: String,
        sessionIndex: Int,
        exerciseId: String,
        sets: [VitalsLogSet]
    ) -> VitalsLog {
        merged(
            existing: existing,
            date: date,
            identity: .legacy(sessionIndex: sessionIndex),
            exerciseId: exerciseId,
            sets: sets
        )
    }

    nonisolated static func merged(
        existing: VitalsLog?,
        date: String,
        sessionIndex: Int,
        note: String
    ) -> VitalsLog {
        merged(
            existing: existing,
            date: date,
            identity: .legacy(sessionIndex: sessionIndex),
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
