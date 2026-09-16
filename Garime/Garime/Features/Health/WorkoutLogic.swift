import Foundation

// MARK: - Entrada de dados

enum WorkoutInputError: Error, Equatable {
    case empty
    case invalid
    case negative
    case zeroReps

    var message: String {
        switch self {
        case .empty: return "preencha o campo"
        case .invalid: return "valor inválido"
        case .negative: return "peso não pode ser negativo"
        case .zeroReps: return "reps precisa ser maior que zero"
        }
    }
}

/// Parsing puro dos campos digitados no celular. Nada aqui toca UI ou rede.
enum WorkoutInput {
    /// Normaliza somente o separador. Nunca remove sinal/letras/dígitos de uma
    /// colagem: dados inválidos precisam permanecer visíveis para validação.
    static func sanitizeWeightText(_ raw: String) -> String {
        raw.replacingOccurrences(of: ".", with: ",")
    }

    static func sanitizeRepsText(_ raw: String) -> String { raw }

    /// `0` é peso corporal e é aceito. Texto vazio nunca vira zero implícito.
    static func parseWeight(_ raw: String) -> Result<Double, WorkoutInputError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        if normalized.hasPrefix("-") { return .failure(.negative) }
        let allowed = CharacterSet(charactersIn: "0123456789.")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              normalized.filter({ $0 == "." }).count <= 1,
              !normalized.hasPrefix("."),
              !normalized.hasSuffix("."),
              (normalized.split(separator: ".").last?.count ?? 0) <= 2 || !normalized.contains(".") else {
            return .failure(.invalid)
        }
        guard let value = Double(normalized), value.isFinite, value <= 10_000 else {
            return .failure(.invalid)
        }
        guard value >= 0 else { return .failure(.negative) }
        return .success(value)
    }

    static func parseReps(_ raw: String) -> Result<Int, WorkoutInputError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(trimmed), value <= 999 else { return .failure(.invalid) }
        guard value > 0 else { return .failure(.zeroReps) }
        return .success(value)
    }

    /// Texto pré-preenchido para o campo de peso (sugestão, nunca execução).
    static func weightText(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value <= 10_000 else { return "" }
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Timer de descanso

/// Timer ancorado em `deadline` (Date absoluto), nunca em ticks acumulados,
/// para sobreviver a background / sheet fechada.
struct RestTimerState: Codable, Equatable {
    let exerciseId: String
    let day: String
    let setIndex: Int
    let duration: Int
    var deadline: Date
}

enum RestTimerRules {
    static let fallbackSeconds = 90

    static func duration(restSec: Int?) -> Int {
        guard let restSec, restSec > 0 else { return fallbackSeconds }
        return restSec
    }

    static func deadline(from start: Date, seconds: Int) -> Date {
        start.addingTimeInterval(TimeInterval(max(0, seconds)))
    }

    /// Segundos restantes arredondados para cima; nunca negativo.
    static func remaining(deadline: Date, now: Date) -> Int {
        let delta = deadline.timeIntervalSince(now)
        guard delta > 0 else { return 0 }
        return Int(delta.rounded(.up))
    }

    static func isFinished(deadline: Date, now: Date) -> Bool {
        remaining(deadline: deadline, now: now) == 0
    }

    static func format(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    /// Descarta timer de outro dia (app aberto no dia seguinte) ou vencido há muito tempo.
    static func isStale(_ state: RestTimerState, day: String, now: Date) -> Bool {
        if state.day != day { return true }
        return now.timeIntervalSince(state.deadline) > 60 * 60
    }
}

// MARK: - Progresso

struct ExerciseProgress: Equatable {
    let done: Int
    let target: Int

    var isComplete: Bool { target > 0 && done >= target }
    var isStarted: Bool { done > 0 }
    var isPartial: Bool { isStarted && !isComplete }
    var fraction: Double {
        guard target > 0 else { return 0 }
        return min(1, Double(done) / Double(target))
    }
}

struct SessionProgress: Equatable {
    let setsDone: Int
    let setsTarget: Int
    let exercisesDone: Int
    let exercisesTarget: Int

    var fraction: Double {
        guard setsTarget > 0 else { return 0 }
        return min(1, Double(setsDone) / Double(setsTarget))
    }

    var isComplete: Bool { exercisesTarget > 0 && exercisesDone >= exercisesTarget }
}

enum WorkoutProgress {
    /// Exercícios por tempo não têm série registrável (o backend só aceita reps),
    /// então ficam fora da conta de progresso.
    static func isTrackable(_ exercise: VitalsExercise) -> Bool {
        exercise.doseType == .reps && !exercise.sets.isEmpty
    }

    static func exercise(prescribed: [[Int]], loggedSets: Int) -> ExerciseProgress {
        ExerciseProgress(done: max(0, loggedSets), target: prescribed.count)
    }

    static func session(
        exercises: [VitalsExercise],
        loggedSets: (String) -> Int
    ) -> SessionProgress {
        var setsDone = 0
        var setsTarget = 0
        var exercisesDone = 0
        var exercisesTarget = 0
        for item in exercises where isTrackable(item) {
            let progress = exercise(prescribed: item.sets, loggedSets: loggedSets(item.id))
            setsDone += min(progress.done, progress.target)
            setsTarget += progress.target
            exercisesTarget += 1
            if progress.isComplete { exercisesDone += 1 }
        }
        return SessionProgress(
            setsDone: setsDone,
            setsTarget: setsTarget,
            exercisesDone: exercisesDone,
            exercisesTarget: exercisesTarget
        )
    }

    /// Exercício atual: o primeiro iniciado e incompleto; senão o primeiro não iniciado.
    static func current(
        exercises: [VitalsExercise],
        loggedSets: (String) -> Int
    ) -> VitalsExercise? {
        let trackable = exercises.filter(isTrackable)
        let partial = trackable.first { item in
            let progress = exercise(prescribed: item.sets, loggedSets: loggedSets(item.id))
            return progress.isPartial
        }
        if let partial { return partial }
        return trackable.first { item in
            !exercise(prescribed: item.sets, loggedSets: loggedSets(item.id)).isComplete
        }
    }

    static func next(
        exercises: [VitalsExercise],
        after currentId: String?,
        loggedSets: (String) -> Int
    ) -> VitalsExercise? {
        let pending = exercises.filter { item in
            isTrackable(item) && !exercise(prescribed: item.sets, loggedSets: loggedSets(item.id)).isComplete
        }
        guard let currentId else { return pending.first }
        guard let index = pending.firstIndex(where: { $0.id == currentId }) else { return pending.first }
        return pending[safe: index + 1]
    }

    /// Alvo de reps sugerido (topo da faixa) — sugestão de prompt, nunca valor salvo.
    static func suggestedReps(prescribed: [[Int]], index: Int) -> Int? {
        prescribed[safe: index]?.last
    }
}
