import XCTest
@testable import Garime

final class HealthLogMergeTests: XCTestCase {
    private func log(id: String, date: String, exercises: [VitalsLogExercise], note: String = "") -> VitalsLog {
        VitalsLog(id: id, date: date, sessionIndex: 1, exercises: exercises, note: note)
    }

    func testMergeKeepsOtherExercises() {
        let existing = log(
            id: "log-1",
            date: "2026-08-04",
            exercises: [
                VitalsLogExercise(id: "supino", sets: [VitalsLogSet(reps: 12, kg: 40)]),
                VitalsLogExercise(id: "remada", sets: [VitalsLogSet(reps: 10, kg: 35)]),
            ]
        )

        let merged = HealthViewModel.merged(
            existing: existing,
            date: "2026-08-04",
            sessionIndex: 1,
            exerciseId: "remada",
            sets: [VitalsLogSet(reps: 8, kg: 37.5)]
        )

        XCTAssertEqual(merged.exercises.count, 2)
        XCTAssertEqual(merged.exercises[0].id, "supino")
        XCTAssertEqual(merged.exercises[0].sets[0].reps, 12)
        XCTAssertEqual(merged.exercises[1].id, "remada")
        XCTAssertEqual(merged.exercises[1].sets[0].kg, 37.5)
    }

    func testMergeNeverReusesALogFromAnotherDate() {
        let existing = log(id: "log-1", date: "2026-08-04", exercises: [], note: "leve")

        let merged = HealthViewModel.merged(
            existing: existing,
            date: "2026-08-05",
            sessionIndex: 2,
            exerciseId: "supino",
            sets: [VitalsLogSet(reps: 10, kg: 40)]
        )

        XCTAssertNotEqual(merged.id, "log-1")
        XCTAssertEqual(merged.date, "2026-08-05")
        XCTAssertEqual(merged.sessionIndex, 2)
        XCTAssertEqual(merged.note, "")
    }

    func testMergeCreatesLogWhenNoneExists() {
        let merged = HealthViewModel.merged(
            existing: nil,
            date: "2026-08-04",
            sessionIndex: 3,
            exerciseId: "agachamento",
            sets: [VitalsLogSet(reps: 10, kg: 60)]
        )

        XCTAssertFalse(merged.id.isEmpty)
        XCTAssertEqual(merged.date, "2026-08-04")
        XCTAssertEqual(merged.exercises.count, 1)
        XCTAssertEqual(merged.exercises[0].id, "agachamento")
    }

    func testEmptySetsRemovesEntryOnly() {
        let existing = log(
            id: "log-1",
            date: "2026-08-04",
            exercises: [
                VitalsLogExercise(id: "supino", sets: [VitalsLogSet(reps: 12, kg: 40)]),
                VitalsLogExercise(id: "remada", sets: [VitalsLogSet(reps: 10, kg: 35)]),
            ]
        )

        let merged = HealthViewModel.merged(
            existing: existing,
            date: "2026-08-04",
            sessionIndex: 1,
            exerciseId: "supino",
            sets: []
        )

        XCTAssertEqual(merged.exercises.map(\.id), ["remada"])
    }

    func testNoteMergeKeepsExercises() {
        let existing = log(
            id: "log-1",
            date: "2026-08-04",
            exercises: [VitalsLogExercise(id: "supino", sets: [VitalsLogSet(reps: 12, kg: 40)])],
            note: ""
        )

        let merged = HealthViewModel.merged(
            existing: existing,
            date: "2026-08-04",
            sessionIndex: 1,
            note: "ombro doendo"
        )

        XCTAssertEqual(merged.id, "log-1")
        XCTAssertEqual(merged.note, "ombro doendo")
        XCTAssertEqual(merged.exercises.count, 1)
    }

    func testPlanMergeSwitchesProvenanceAndDeduplicatesExercise() {
        let existing = VitalsLog(
            id: "log-1",
            date: "2026-08-24",
            sessionIndex: 1,
            exercises: [
                VitalsLogExercise(id: "remada-baixa", sets: [VitalsLogSet(reps: 10, kg: 30)]),
                VitalsLogExercise(id: "remada-baixa", sets: [VitalsLogSet(reps: 11, kg: 30)]),
                VitalsLogExercise(id: "rosca-w", sets: [VitalsLogSet(reps: 12, kg: 10)]),
            ],
            note: "leve"
        )

        let merged = HealthViewModel.merged(
            existing: existing,
            date: "2026-08-24",
            identity: .plan(planId: "plan-2026-W35.r1", planDayId: "2026-08-24"),
            exerciseId: "remada-baixa",
            sets: [VitalsLogSet(reps: 12, kg: 35)]
        )

        XCTAssertNil(merged.sessionIndex)
        XCTAssertEqual(merged.planId, "plan-2026-W35.r1")
        XCTAssertEqual(merged.planDayId, "2026-08-24")
        XCTAssertEqual(merged.exercises.map(\.id), ["remada-baixa", "rosca-w"])
        XCTAssertEqual(merged.note, "leve")
    }

    func testPlanNoteMergeKeepsPlanIdentityAndExercises() {
        let existing = VitalsLog(
            id: "log-1",
            date: "2026-08-24",
            planId: "plan-2026-W35.r1",
            planDayId: "2026-08-24",
            exercises: [VitalsLogExercise(id: "remada-baixa", sets: [VitalsLogSet(reps: 12, kg: 35)])],
            note: ""
        )

        let merged = HealthViewModel.merged(
            existing: existing,
            date: "2026-08-24",
            identity: .plan(planId: "plan-2026-W35.r2", planDayId: "2026-08-24"),
            note: "sessão concluída"
        )

        XCTAssertNil(merged.sessionIndex)
        XCTAssertEqual(merged.planId, "plan-2026-W35.r2")
        XCTAssertEqual(merged.planDayId, "2026-08-24")
        XCTAssertEqual(merged.exercises.map(\.id), ["remada-baixa"])
        XCTAssertEqual(merged.note, "sessão concluída")
    }

    func testLegacyAndPlanLogCodableShapesRemainExclusive() throws {
        let legacyData = Data(#"{"id":"old","date":"2026-08-23","sessionIndex":2,"exercises":[],"note":"ok"}"#.utf8)
        let legacy = try JSONDecoder().decode(VitalsLog.self, from: legacyData)
        XCTAssertEqual(legacy.sessionIndex, 2)
        XCTAssertNil(legacy.planId)

        let plan = VitalsLog(
            id: "new",
            date: "2026-08-24",
            planId: "plan-2026-W35.r1",
            planDayId: "2026-08-24",
            exercises: [],
            note: ""
        )
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        XCTAssertNil(encoded["sessionIndex"])
        XCTAssertEqual(encoded["planId"] as? String, "plan-2026-W35.r1")
        XCTAssertEqual(encoded["planDayId"] as? String, "2026-08-24")

        let legacyEncoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertEqual(legacyEncoded["sessionIndex"] as? Int, 2)
        XCTAssertNil(legacyEncoded["planId"])
        XCTAssertNil(legacyEncoded["planDayId"])
    }
}
