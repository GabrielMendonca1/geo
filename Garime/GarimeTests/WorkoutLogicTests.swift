import XCTest
@testable import Garime

final class WorkoutInputTests: XCTestCase {
    func testWeightAcceptsCommaAndDot() {
        XCTAssertEqual(try weight("12,5"), 12.5)
        XCTAssertEqual(try weight("12.5"), 12.5)
        XCTAssertEqual(try weight(" 40 "), 40)
    }

    func testWeightZeroIsBodyweight() {
        XCTAssertEqual(try weight("0"), 0)
        XCTAssertEqual(try weight("0,0"), 0)
    }

    func testWeightRejectsEmptyInsteadOfSilentZero() {
        XCTAssertEqual(WorkoutInput.parseWeight(""), .failure(.empty))
        XCTAssertEqual(WorkoutInput.parseWeight("   "), .failure(.empty))
    }

    func testWeightRejectsGarbageAndNonFinite() {
        XCTAssertEqual(WorkoutInput.parseWeight("abc"), .failure(.invalid))
        XCTAssertEqual(WorkoutInput.parseWeight("12,,5"), .failure(.invalid))
        XCTAssertEqual(WorkoutInput.parseWeight("1.2.3"), .failure(.invalid))
        XCTAssertEqual(WorkoutInput.parseWeight("inf"), .failure(.invalid))
        XCTAssertEqual(WorkoutInput.parseWeight("nan"), .failure(.invalid))
        XCTAssertEqual(WorkoutInput.parseWeight("1e9"), .failure(.invalid))
        XCTAssertEqual(WorkoutInput.parseWeight("12,"), .failure(.invalid))
        XCTAssertEqual(WorkoutInput.parseWeight(",5"), .failure(.invalid))
    }

    func testWeightRejectsNegative() {
        XCTAssertEqual(WorkoutInput.parseWeight("-5"), .failure(.negative))
    }

    func testPastedInvalidWeightIsNeverSilentlyRewrittenAsValid() {
        XCTAssertEqual(WorkoutInput.sanitizeWeightText("12.5"), "12,5")
        for raw in ["12,,5", "12,555", ",5", "1a2", "5kg0", "1e5"] {
            XCTAssertEqual(WorkoutInput.parseWeight(WorkoutInput.sanitizeWeightText(raw)), .failure(.invalid))
        }
        XCTAssertEqual(WorkoutInput.parseWeight(WorkoutInput.sanitizeWeightText("-50")), .failure(.negative))
        XCTAssertEqual(WorkoutInput.parseWeight(String(repeating: "9", count: 308)), .failure(.invalid))
    }

    func testRepsDoesNotStripSignsOrDecimalsOrTruncatePastes() {
        for raw in ["-3", "1.5", "1000", "2reps"] {
            XCTAssertEqual(WorkoutInput.sanitizeRepsText(raw), raw)
            XCTAssertEqual(WorkoutInput.parseReps(raw), .failure(.invalid))
        }
    }

    func testUntrustedHistoricalWeightCannotCrashFormatting() {
        XCTAssertEqual(WorkoutInput.weightText(1e20), "")
        XCTAssertEqual(WorkoutInput.weightText(.infinity), "")
        XCTAssertEqual(WorkoutInput.weightText(.nan), "")
        XCTAssertEqual(WorkoutInput.weightText(2.999), "3")
    }

    func testRepsRejectsZeroAndEmpty() {
        XCTAssertEqual(WorkoutInput.parseReps("0"), .failure(.zeroReps))
        XCTAssertEqual(WorkoutInput.parseReps(""), .failure(.empty))
        XCTAssertEqual(WorkoutInput.parseReps("8"), .success(8))
    }

    func testWeightTextRoundTrip() {
        XCTAssertEqual(WorkoutInput.weightText(40), "40")
        XCTAssertEqual(WorkoutInput.weightText(37.5), "37,5")
        XCTAssertEqual(WorkoutInput.weightText(0), "0")
        XCTAssertEqual(try weight(WorkoutInput.weightText(0)), 0)
        XCTAssertEqual(WorkoutInput.weightText(nil), "")
        XCTAssertEqual(try weight(WorkoutInput.weightText(37.5)), 37.5)
    }

    private func weight(_ text: String) throws -> Double {
        switch WorkoutInput.parseWeight(text) {
        case .success(let value): return value
        case .failure(let error): throw NSError(domain: "weight", code: 0, userInfo: [NSLocalizedDescriptionKey: error.message])
        }
    }
}

final class RestTimerRulesTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testFallbackIs90Seconds() {
        XCTAssertEqual(RestTimerRules.duration(restSec: nil), 90)
        XCTAssertEqual(RestTimerRules.duration(restSec: 0), 90)
        XCTAssertEqual(RestTimerRules.duration(restSec: -5), 90)
        XCTAssertEqual(RestTimerRules.duration(restSec: 120), 120)
    }

    func testRemainingUsesDeadlineNotTicks() {
        let deadline = RestTimerRules.deadline(from: base, seconds: 90)
        XCTAssertEqual(RestTimerRules.remaining(deadline: deadline, now: base), 90)
        // app em background por 30s: a conta continua correta
        XCTAssertEqual(RestTimerRules.remaining(deadline: deadline, now: base.addingTimeInterval(30)), 60)
        XCTAssertEqual(RestTimerRules.remaining(deadline: deadline, now: base.addingTimeInterval(89.4)), 1)
        XCTAssertEqual(RestTimerRules.remaining(deadline: deadline, now: base.addingTimeInterval(300)), 0)
    }

    func testFormatIsMinutesSeconds() {
        XCTAssertEqual(RestTimerRules.format(90), "01:30")
        XCTAssertEqual(RestTimerRules.format(0), "00:00")
        XCTAssertEqual(RestTimerRules.format(-3), "00:00")
        XCTAssertEqual(RestTimerRules.format(605), "10:05")
    }

    func testIsFinished() {
        let deadline = RestTimerRules.deadline(from: base, seconds: 60)
        XCTAssertFalse(RestTimerRules.isFinished(deadline: deadline, now: base))
        XCTAssertTrue(RestTimerRules.isFinished(deadline: deadline, now: base.addingTimeInterval(61)))
    }

    func testStaleDropsOtherDayOrAncientTimer() {
        let state = RestTimerState(
            exerciseId: "supino",
            day: "2026-08-24",
            setIndex: 0,
            duration: 90,
            deadline: RestTimerRules.deadline(from: base, seconds: 90)
        )
        XCTAssertFalse(RestTimerRules.isStale(state, day: "2026-08-24", now: base.addingTimeInterval(30)))
        XCTAssertTrue(RestTimerRules.isStale(state, day: "2026-08-25", now: base.addingTimeInterval(30)))
        XCTAssertTrue(RestTimerRules.isStale(state, day: "2026-08-24", now: base.addingTimeInterval(7200)))
    }

    func testStateSurvivesRoundTrip() throws {
        let state = RestTimerState(exerciseId: "remada", day: "2026-08-24", setIndex: 2, duration: 120, deadline: base)
        let decoded = try JSONDecoder().decode(RestTimerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }
}

final class WorkoutProgressTests: XCTestCase {
    private func exercise(
        _ id: String,
        sets: [[Int]] = [[8, 12], [8, 12], [8, 12]],
        dose: TrainingDoseType = .reps,
        rest: Int? = nil
    ) -> VitalsExercise {
        VitalsExercise(id: id, name: id, sets: sets, muscles: [], restSec: rest, doseType: dose)
    }

    func testPartialExerciseIsNotComplete() {
        let progress = WorkoutProgress.exercise(prescribed: [[8], [8], [8]], loggedSets: 2)
        XCTAssertTrue(progress.isStarted)
        XCTAssertTrue(progress.isPartial)
        XCTAssertFalse(progress.isComplete)
        XCTAssertEqual(progress.fraction, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testCompleteRequiresAllPrescribedSets() {
        XCTAssertTrue(WorkoutProgress.exercise(prescribed: [[8], [8]], loggedSets: 2).isComplete)
        XCTAssertTrue(WorkoutProgress.exercise(prescribed: [[8], [8]], loggedSets: 3).isComplete)
        XCTAssertFalse(WorkoutProgress.exercise(prescribed: [], loggedSets: 2).isComplete)
    }

    func testSessionProgressIgnoresDurationExercises() {
        let exercises = [
            exercise("supino"),
            exercise("prancha", sets: [[45]], dose: .timeSec),
            exercise("remada", sets: [[10], [10]]),
        ]
        let logged = ["supino": 3, "remada": 1, "prancha": 9]
        let summary = WorkoutProgress.session(exercises: exercises) { logged[$0] ?? 0 }

        XCTAssertEqual(summary.setsTarget, 5)
        XCTAssertEqual(summary.setsDone, 4)
        XCTAssertEqual(summary.exercisesTarget, 2)
        XCTAssertEqual(summary.exercisesDone, 1)
        XCTAssertFalse(summary.isComplete)
    }

    func testSessionProgressClampsExtraSets() {
        let summary = WorkoutProgress.session(exercises: [exercise("supino", sets: [[8], [8]])]) { _ in 5 }
        XCTAssertEqual(summary.setsDone, 2)
        XCTAssertEqual(summary.setsTarget, 2)
        XCTAssertTrue(summary.isComplete)
    }

    func testCurrentPrefersPartialThenFirstPending() {
        let exercises = [exercise("supino", sets: [[8], [8]]), exercise("remada", sets: [[8], [8]])]
        let done = ["supino": 2, "remada": 1]
        XCTAssertEqual(WorkoutProgress.current(exercises: exercises) { done[$0] ?? 0 }?.id, "remada")

        XCTAssertEqual(WorkoutProgress.current(exercises: exercises) { _ in 0 }?.id, "supino")
        XCTAssertNil(WorkoutProgress.current(exercises: exercises) { _ in 2 })
    }

    func testNextSkipsCompletedAndDuration() {
        let exercises = [
            exercise("supino", sets: [[8], [8]]),
            exercise("prancha", sets: [[45]], dose: .timeSec),
            exercise("remada", sets: [[8], [8]]),
            exercise("rosca", sets: [[8], [8]]),
        ]
        let done = ["supino": 1]
        let next = WorkoutProgress.next(exercises: exercises, after: "supino") { done[$0] ?? 0 }
        XCTAssertEqual(next?.id, "remada")
        XCTAssertNil(WorkoutProgress.next(exercises: exercises, after: "rosca") { done[$0] ?? 0 })
    }

    func testSuggestedRepsIsTopOfRangeAndNeverLogged() {
        XCTAssertEqual(WorkoutProgress.suggestedReps(prescribed: [[8, 12]], index: 0), 12)
        XCTAssertNil(WorkoutProgress.suggestedReps(prescribed: [[8, 12]], index: 3))
    }

    func testTrackabilityExcludesTimeDoses() {
        XCTAssertTrue(WorkoutProgress.isTrackable(exercise("supino")))
        XCTAssertFalse(WorkoutProgress.isTrackable(exercise("prancha", sets: [[45]], dose: .timeSec)))
        XCTAssertFalse(WorkoutProgress.isTrackable(exercise("bike", sets: [[20]], dose: .timeMin)))
        XCTAssertFalse(WorkoutProgress.isTrackable(exercise("vazio", sets: [])))
    }
}

@MainActor
final class WorkoutSessionModelTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "workout.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testRestSurvivesNewModelInstanceSameDay() {
        let defaults = makeDefaults()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = WorkoutSessionModel(defaults: defaults, now: { now })
        model.adopt(day: "2026-08-24")
        model.startRest(exerciseId: "supino", setIndex: 0, restSec: 120)
        XCTAssertEqual(model.remaining, 120)

        now = now.addingTimeInterval(45)
        let reopened = WorkoutSessionModel(defaults: defaults, now: { now })
        reopened.adopt(day: "2026-08-24")
        XCTAssertEqual(reopened.remaining, 75)
        XCTAssertEqual(reopened.rest?.exerciseId, "supino")
    }

    func testRestFromAnotherDayIsDropped() {
        let defaults = makeDefaults()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = WorkoutSessionModel(defaults: defaults, now: { now })
        model.adopt(day: "2026-08-24")
        model.startRest(exerciseId: "supino", setIndex: 0, restSec: 90)

        now = now.addingTimeInterval(86_400)
        let next = WorkoutSessionModel(defaults: defaults, now: { now })
        next.adopt(day: "2026-08-25")
        XCTAssertNil(next.rest)
        XCTAssertEqual(next.remaining, 0)
    }

    func testSkipAndRestart() {
        let defaults = makeDefaults()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = WorkoutSessionModel(defaults: defaults, now: { now })
        model.adopt(day: "2026-08-24")
        model.startRest(exerciseId: "supino", setIndex: 0, restSec: 60)

        now = now.addingTimeInterval(30)
        model.tick()
        XCTAssertEqual(model.remaining, 30)
        model.restartRest()
        XCTAssertEqual(model.remaining, 60)
        XCTAssertEqual(model.restLabel, "01:00")

        model.skipRest()
        XCTAssertNil(model.rest)
        XCTAssertFalse(model.isResting)
    }

    func testDraftsRoundTripPerExerciseAndDay() {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = WorkoutSessionModel(defaults: defaults, now: { now })
        model.adopt(day: "2026-08-24")
        model.saveDraft([SetDraft(reps: "10", kg: "37,5")], for: "supino")

        let reopened = WorkoutSessionModel(defaults: defaults, now: { now })
        reopened.adopt(day: "2026-08-24")
        XCTAssertEqual(reopened.draft(for: "supino"), [SetDraft(reps: "10", kg: "37,5")])

        let otherDay = WorkoutSessionModel(defaults: defaults, now: { now })
        otherDay.adopt(day: "2026-08-25")
        XCTAssertTrue(otherDay.draft(for: "supino").isEmpty)
    }

    func testEmptyDraftIsNotStored() {
        let defaults = makeDefaults()
        let model = WorkoutSessionModel(defaults: defaults, now: { Date() })
        model.adopt(day: "2026-08-24")
        model.saveDraft([SetDraft(), SetDraft()], for: "supino")
        XCTAssertTrue(model.draft(for: "supino").isEmpty)
    }
}
