import Combine
import Foundation
import UIKit

/// Rascunho local de uma série (texto cru digitado). Nunca é log: só sobrevive
/// ao fechar a sheet para o dedo não perder o que digitou.
struct SetDraft: Codable, Equatable {
    var reps: String = ""
    var kg: String = ""

    var isEmpty: Bool { reps.isEmpty && kg.isEmpty }
}

/// Estado de treino que precisa viver fora da sheet: timer de descanso
/// (ancorado em `Date`) e rascunhos por exercício/dia. Tudo local, sem rede,
/// sem notificação e sem permissão nova.
@MainActor
final class WorkoutSessionModel: ObservableObject {
    @Published private(set) var rest: RestTimerState?
    @Published private(set) var remaining: Int = 0
    @Published private var drafts: [String: [SetDraft]] = [:]

    private let defaults: UserDefaults
    private let now: () -> Date
    private(set) var day: String = ""
    private var ticker: Timer?
    private var didBuzz = false

    private static let restKey = "garime.workout.rest.v1"
    private static let draftPrefix = "garime.workout.drafts.v1."

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    deinit {
        ticker?.invalidate()
    }

    var isResting: Bool {
        guard let rest else { return false }
        return RestTimerRules.remaining(deadline: rest.deadline, now: now()) > 0
    }

    var restLabel: String {
        RestTimerRules.format(remaining)
    }

    // MARK: - Ciclo de vida

    func adopt(day: String) {
        guard !day.isEmpty else { return }
        if day != self.day {
            self.day = day
            drafts = loadDrafts(day: day)
        }
        if let stored = loadRest(), !RestTimerRules.isStale(stored, day: day, now: now()) {
            rest = stored
        } else {
            rest = nil
            defaults.removeObject(forKey: Self.restKey)
        }
        syncRemaining()
        startTickerIfNeeded()
    }

    // MARK: - Timer

    func startRest(exerciseId: String, setIndex: Int, restSec: Int?) {
        guard !day.isEmpty else { return }
        let seconds = RestTimerRules.duration(restSec: restSec)
        let state = RestTimerState(
            exerciseId: exerciseId,
            day: day,
            setIndex: setIndex,
            duration: seconds,
            deadline: RestTimerRules.deadline(from: now(), seconds: seconds)
        )
        rest = state
        didBuzz = false
        persistRest(state)
        syncRemaining()
        startTickerIfNeeded()
    }

    func skipRest() {
        rest = nil
        remaining = 0
        didBuzz = false
        defaults.removeObject(forKey: Self.restKey)
        stopTicker()
    }

    func restartRest() {
        guard var state = rest else { return }
        state.deadline = RestTimerRules.deadline(from: now(), seconds: state.duration)
        rest = state
        didBuzz = false
        persistRest(state)
        syncRemaining()
        startTickerIfNeeded()
    }

    func tick() {
        syncRemaining()
        if remaining == 0 {
            stopTicker()
            if rest != nil, !didBuzz {
                didBuzz = true
                if UIApplication.shared.applicationState == .active { Haptics.restFinished() }
            }
        }
    }

    private func syncRemaining() {
        guard let rest else {
            remaining = 0
            return
        }
        remaining = RestTimerRules.remaining(deadline: rest.deadline, now: now())
    }

    private func startTickerIfNeeded() {
        stopTicker()
        guard rest != nil, remaining > 0 else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func persistRest(_ state: RestTimerState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.restKey)
    }

    private func loadRest() -> RestTimerState? {
        guard let data = defaults.data(forKey: Self.restKey) else { return nil }
        return try? JSONDecoder().decode(RestTimerState.self, from: data)
    }

    // MARK: - Rascunhos

    func draft(for exerciseId: String) -> [SetDraft] {
        drafts[exerciseId] ?? []
    }

    func saveDraft(_ rows: [SetDraft], for exerciseId: String) {
        if rows.allSatisfy(\.isEmpty) {
            drafts.removeValue(forKey: exerciseId)
        } else {
            drafts[exerciseId] = rows
        }
        persistDrafts()
    }

    func clearDraft(for exerciseId: String) {
        drafts.removeValue(forKey: exerciseId)
        persistDrafts()
    }

    private func persistDrafts() {
        guard !day.isEmpty else { return }
        let key = Self.draftPrefix + day
        if drafts.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        defaults.set(data, forKey: key)
    }

    private func loadDrafts(day: String) -> [String: [SetDraft]] {
        guard let data = defaults.data(forKey: Self.draftPrefix + day),
              let decoded = try? JSONDecoder().decode([String: [SetDraft]].self, from: data) else { return [:] }
        return decoded
    }
}

/// Haptics em primeiro plano. Não substitui alarme com tela bloqueada.
enum Haptics {
    static func setLogged() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func restFinished() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func failure() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
