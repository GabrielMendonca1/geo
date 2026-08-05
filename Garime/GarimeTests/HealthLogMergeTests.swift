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

    func testMergeReusesIdAndDateOfTodayLog() {
        let existing = log(id: "log-1", date: "2026-08-04", exercises: [], note: "leve")

        let merged = HealthViewModel.merged(
            existing: existing,
            date: "2026-08-05",
            sessionIndex: 2,
            exerciseId: "supino",
            sets: [VitalsLogSet(reps: 10, kg: 40)]
        )

        XCTAssertEqual(merged.id, "log-1")
        XCTAssertEqual(merged.date, "2026-08-04")
        XCTAssertEqual(merged.sessionIndex, 2)
        XCTAssertEqual(merged.note, "leve")
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
}
