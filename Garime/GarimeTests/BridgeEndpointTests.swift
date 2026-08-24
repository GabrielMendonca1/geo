import XCTest
@testable import Garime

final class BridgeEndpointTests: XCTestCase {
    func testHealthPathIsCorrect() {
        XCTAssertEqual(BridgeEndpoint.health.path, "/health")
    }

    func testBridgeDoesNotWaitForeverWhenTailnetIsUnavailable() {
        XCTAssertFalse(BridgeClient.session.configuration.waitsForConnectivity)
    }

    func testTaskCRUDPathsAreCorrect() {
        let id = "task-123"
        XCTAssertEqual(BridgeEndpoint.tasksList.path, "/tasks")
        XCTAssertEqual(BridgeEndpoint.tasksCreate.path, "/tasks")
        XCTAssertEqual(BridgeEndpoint.taskComplete(id: id).path, "/tasks/task-123/complete")
        XCTAssertEqual(BridgeEndpoint.taskReopen(id: id).path, "/tasks/task-123/reopen")
        XCTAssertEqual(BridgeEndpoint.taskDelete(id: id).path, "/tasks/task-123")
    }

    func testPercentEncodingInTermSession() {
        XCTAssertEqual(
            BridgeEndpoint.termStream(session: "my session&tab=1").path,
            "/term/stream?session=my%20session%26tab%3D1"
        )
    }

    func testAttachAgentPathEncodesPaneColon() {
        XCTAssertEqual(
            BridgeEndpoint.termAttachAgent(project: "garime", pane: "w1:p3").path,
            "/term/attach-agent?project=garime&pane=w1%3Ap3"
        )
    }

    func testAttachHerdrPathEncodesProject() {
        XCTAssertEqual(
            BridgeEndpoint.termAttachHerdr(project: "meu projeto").path,
            "/term/attach-herdr?project=meu%20projeto"
        )
    }

    func testPercentEncodingInTaskID() {
        XCTAssertEqual(
            BridgeEndpoint.taskComplete(id: "work/50% #1").path,
            "/tasks/work%2F50%25%20%231/complete"
        )
    }

    func testTrainingPathsAreCorrectAndWeekIsEncoded() {
        XCTAssertEqual(BridgeEndpoint.vitalsCatalog.path, "/vitals/catalog")
        XCTAssertEqual(BridgeEndpoint.vitalsBlocks.path, "/vitals/blocks")
        XCTAssertEqual(
            BridgeEndpoint.vitalsPlan(week: "2026-W32&next=true").path,
            "/vitals/plan?week=2026-W32%26next%3Dtrue"
        )
    }

    func testCatalogDecoderAcceptsUnknownFieldsAndKeepsStableID() throws {
        let data = Data(#"""
        {"schema":"vitals.catalog/1","id":"demo-catalog","version":1,"updatedAt":"2026-08-03T18:00:00Z","future":true,
         "exercises":[{"id":"demo.remada-maquina","name":"Remada (demo)","status":"active","muscles":["upper-back"],"equipment":"machine","tags":["demo"],"future":"value"}]}
        """#.utf8)
        let catalog = try JSONDecoder().decode(TrainingCatalog.self, from: data)
        XCTAssertEqual(catalog.id, "demo-catalog")
        XCTAssertEqual(catalog.exercises.first?.id, "demo.remada-maquina")
    }

    func testRealStaticCatalogAndBlocksDecodeWithCurrentSchema() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let training = repositoryRoot.appendingPathComponent("GeoBridge/training")
        let catalogData = try Data(contentsOf: training.appendingPathComponent("catalog.json"))
        let blocksData = try Data(contentsOf: training.appendingPathComponent("blocks.json"))

        let catalog = try JSONDecoder().decode(TrainingCatalog.self, from: catalogData)
        let blocks = try JSONDecoder().decode(TrainingBlocks.self, from: blocksData)

        XCTAssertEqual(catalog.exercises.count, 37)
        XCTAssertFalse(blocks.blocks.isEmpty)
    }

    func testCatalogDecoderRejectsMissingOrInvalidID() {
        let missing = Data(#"{"schema":"vitals.catalog/1","version":1,"updatedAt":"now","exercises":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TrainingCatalog.self, from: missing))

        let invalid = Data(#"{"schema":"vitals.catalog/1","id":"bad/id","version":1,"updatedAt":"now","exercises":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TrainingCatalog.self, from: invalid))
    }

    func testTrainingRepositoryTreats404AsEmptyButNotInvalidJSON() async throws {
        let empty = FakeTrainingBridge(result: .failure(BridgeError.server(status: 404, code: "not_found")))
        let emptyRepository = BridgeTrainingRepository(client: empty)
        let catalog = try await emptyRepository.fetchCatalog()
        let plan = try await emptyRepository.fetchPlan(week: "2026-W35")
        XCTAssertNil(catalog)
        XCTAssertNil(plan)

        let invalid = FakeTrainingBridge(result: .success(Data("not-json".utf8)))
        let invalidRepository = BridgeTrainingRepository(client: invalid)
        do {
            _ = try await invalidRepository.fetchCatalog()
            XCTFail("invalid JSON must remain a visible error")
        } catch is DecodingError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTrainingRepositoryDiscardsAPlanFromAnotherWeek() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("GeoBridge/fixtures/training/plan-2026-W35.r1.json"))
        let fake = FakeTrainingBridge(routes: [
            BridgeEndpoint.vitalsPlan(week: "2026-W36").path: .success(data),
        ])
        let repository = BridgeTrainingRepository(client: fake)
        let plan = try await repository.fetchPlan(week: "2026-W36")

        XCTAssertNil(plan)
    }

    func testTrainingClockUsesOneTimezoneAcrossISOWeekBoundaries() throws {
        let clock = TrainingClock(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        let sunday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2021-01-03T23:30:00Z"))
        let monday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2021-01-04T00:30:00Z"))

        XCTAssertEqual(clock.keys(for: sunday).week, "2020-W53")
        XCTAssertEqual(clock.keys(for: sunday).day, "2021-01-03")
        XCTAssertEqual(clock.keys(for: monday).week, "2021-W01")
        XCTAssertEqual(clock.keys(for: monday).day, "2021-01-04")
        XCTAssertEqual(clock.dayKeys(forWeek: "2021-W01")?.first, "2021-01-04")
    }

    func testWeeklyPlanItemAdapterKeepsStableIdentityRangesAndRest() throws {
        let data = Data(#"{"exerciseId":"remada-baixa","name":"Remada baixa","muscles":["upper-back"],"sets":[[10,12],[8,10]],"restSec":75}"#.utf8)
        let item = try JSONDecoder().decode(WeeklyPlanItem.self, from: data)
        let exercise = item.vitalsExercise

        XCTAssertEqual(exercise.id, "remada-baixa")
        XCTAssertEqual(exercise.name, "Remada baixa")
        XCTAssertEqual(exercise.sets, [[10, 12], [8, 10]])
        XCTAssertEqual(exercise.muscles, ["upper-back"])
        XCTAssertEqual(exercise.restSec, 75)
    }

    @MainActor
    func testInvalidCatalogDoesNotPreventValidWeekFromLoading() async throws {
        let invalidCatalog = Data(#"""
        {"schema":"vitals.catalog/1","id":"demo-catalog","version":1,"updatedAt":"2026-08-24T18:00:00Z",
         "exercises":[{"id":"demo.exercise","name":"Demo","status":"paused","muscles":[],"equipment":"none","tags":[]}]}
        """#.utf8)
        let validPlan = Data(#"""
        {"schema":"vitals.plan/1","id":"plan-2026-W35.r1","week":"2026-W35","revision":1,
         "frozenAt":"2026-08-24T18:00:00Z",
         "source":{"catalogId":"demo-catalog","catalogVersion":1,"blocks":[],"generator":"manual"},
         "days":[
           {"date":"2026-08-24","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-25","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-26","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-27","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-28","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-29","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-30","label":"Descanso","rest":true,"items":[]}
         ]}
        """#.utf8)
        let missing = Result<Data, Error>.failure(BridgeError.server(status: 404, code: "not_found"))
        let fake = FakeTrainingBridge(routes: [
            BridgeEndpoint.vitalsCatalog.path: .success(invalidCatalog),
            BridgeEndpoint.vitalsBlocks.path: missing,
            BridgeEndpoint.vitalsPlan(week: "2026-W35").path: .success(validPlan),
        ])
        let model = WeekPlanViewModel(repository: BridgeTrainingRepository(client: fake))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-24T12:00:00Z"))

        await model.reload(date: date)

        XCTAssertEqual(model.plan?.id, "plan-2026-W35.r1")
        XCTAssertNotNil(model.catalogErrorMessage)
        XCTAssertNil(model.planErrorMessage)
        XCTAssertNil(model.blocksErrorMessage)
    }

    @MainActor
    func testHealthUsesCurrentPlanWhenLegacyProtocolFails() async throws {
        let plan = Data(#"""
        {"schema":"vitals.plan/1","id":"plan-2026-W35.r1","week":"2026-W35","revision":1,
         "frozenAt":"2026-08-24T00:00:00Z",
         "source":{"catalogId":"gabriel-catalog","catalogVersion":1,"blocks":[],"generator":"conversation"},
         "days":[
           {"date":"2026-08-24","label":"Treino 1","rest":false,"items":[{"exerciseId":"remada-baixa","name":"Remada baixa","muscles":["upper-back"],"sets":[[10,12]],"restSec":75}]},
           {"date":"2026-08-25","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-26","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-27","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-28","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-29","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-30","label":"Descanso","rest":true,"items":[]}
         ]}
        """#.utf8)
        let fake = FakeTrainingBridge(routes: [
            BridgeEndpoint.vitalsPlan(week: "2026-W35").path: .success(plan),
            BridgeEndpoint.vitalsProtocol.path: .failure(BridgeError.unreachable("legacy unavailable")),
            BridgeEndpoint.vitalsState.path: .failure(BridgeError.server(status: 404, code: "not_found")),
            BridgeEndpoint.vitalsLogs.path: .success(Data("[]".utf8)),
        ])
        let clock = TrainingClock(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-24T12:00:00Z"))
        let model = HealthViewModel(
            repository: BridgeVitalsRepository(client: fake),
            trainingRepository: BridgeTrainingRepository(client: fake),
            clock: clock,
            now: { date }
        )

        await model.reload(date: date)

        XCTAssertTrue(model.isPlanPrimary)
        XCTAssertEqual(model.todaySession?.exercises.first?.id, "remada-baixa")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.needsOnboarding)
    }

    @MainActor
    func testHealthFallsBackToLegacyWhenPlanCannotDecode() async throws {
        let legacy = Data(#"""
        {"id":"legacy","name":"Legado","sessions":[
          {"index":0,"name":"Sessão legado","short":"legado","rest":false,"muscles":["biceps"],
           "exercises":[{"id":"rosca-w","name":"Rosca W","sets":[[10,12]],"muscles":["biceps"]}]}
        ]}
        """#.utf8)
        let state = Data(#"{"protocolId":"legacy","anchorDate":"2026-08-24","anchorIndex":0}"#.utf8)
        let fake = FakeTrainingBridge(routes: [
            BridgeEndpoint.vitalsPlan(week: "2026-W35").path: .success(Data("not-json".utf8)),
            BridgeEndpoint.vitalsProtocol.path: .success(legacy),
            BridgeEndpoint.vitalsState.path: .success(state),
            BridgeEndpoint.vitalsLogs.path: .success(Data("[]".utf8)),
        ])
        let clock = TrainingClock(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-24T12:00:00Z"))
        let model = HealthViewModel(
            repository: BridgeVitalsRepository(client: fake),
            trainingRepository: BridgeTrainingRepository(client: fake),
            clock: clock,
            now: { date }
        )

        await model.reload(date: date)

        XCTAssertFalse(model.isPlanPrimary)
        XCTAssertEqual(model.todaySession?.index, 0)
        XCTAssertEqual(model.todaySession?.exercises.first?.id, "rosca-w")
        XCTAssertNotNil(model.planErrorMessage)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testSaveAfterMidnightReloadsAndNeverRewritesPreviousDay() async throws {
        let plan = Data(#"""
        {"schema":"vitals.plan/1","id":"plan-2026-W35.r1","week":"2026-W35","revision":1,
         "frozenAt":"2026-08-24T00:00:00Z",
         "source":{"catalogId":"gabriel-catalog","catalogVersion":1,"blocks":[],"generator":"conversation"},
         "days":[
           {"date":"2026-08-24","label":"Treino 1","rest":false,"items":[{"exerciseId":"remada-baixa","name":"Remada baixa","muscles":["upper-back"],"sets":[[10,12]],"restSec":75}]},
           {"date":"2026-08-25","label":"Treino 2","rest":false,"items":[{"exerciseId":"remada-baixa","name":"Remada baixa","muscles":["upper-back"],"sets":[[10,12]],"restSec":75}]},
           {"date":"2026-08-26","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-27","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-28","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-29","label":"Descanso","rest":true,"items":[]},
           {"date":"2026-08-30","label":"Descanso","rest":true,"items":[]}
         ]}
        """#.utf8)
        let logs = Data(#"""
        [{"id":"yesterday","date":"2026-08-24","planId":"plan-2026-W35.r1","planDayId":"2026-08-24",
          "exercises":[],"note":"ontem"}]
        """#.utf8)
        let fake = FakeTrainingBridge(routes: [
            BridgeEndpoint.vitalsPlan(week: "2026-W35").path: .success(plan),
            BridgeEndpoint.vitalsProtocol.path: .failure(BridgeError.unreachable("legacy unavailable")),
            BridgeEndpoint.vitalsState.path: .failure(BridgeError.server(status: 404, code: "not_found")),
            BridgeEndpoint.vitalsLogs.path: .success(logs),
        ])
        let clock = TrainingClock(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        let firstDay = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-24T23:50:00Z"))
        let secondDay = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-25T00:05:00Z"))
        let current = MutableDate(firstDay)
        let model = HealthViewModel(
            repository: BridgeVitalsRepository(client: fake),
            trainingRepository: BridgeTrainingRepository(client: fake),
            clock: clock,
            now: { current.value }
        )
        await model.reload(date: firstDay)
        XCTAssertEqual(model.todayLog?.id, "yesterday")

        current.value = secondDay
        try await model.saveExercise(
            exerciseId: "remada-baixa",
            sets: [VitalsLogSet(reps: 12, kg: 40)]
        )

        let post = try XCTUnwrap(fake.posts.first)
        XCTAssertEqual(post.path, BridgeEndpoint.vitalsLog.path)
        let saved = try JSONDecoder().decode(VitalsLog.self, from: post.body)
        XCTAssertEqual(saved.date, "2026-08-25")
        XCTAssertEqual(saved.planDayId, "2026-08-25")
        XCTAssertEqual(saved.planId, "plan-2026-W35.r1")
        XCTAssertNotEqual(saved.id, "yesterday")
        XCTAssertEqual(saved.note, "")
    }
}

private final class MutableDate: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private final class FakeTrainingBridge: BridgeAPI, @unchecked Sendable {
    struct Post {
        let path: String
        let body: Data
    }

    let routes: [String: Result<Data, Error>]
    let fallback: Result<Data, Error>?
    private(set) var posts: [Post] = []

    init(result: Result<Data, Error>) {
        routes = [:]
        fallback = result
    }

    init(routes: [String: Result<Data, Error>]) {
        self.routes = routes
        fallback = nil
    }

    func getData(_ path: String, token: String?) async throws -> Data {
        if let result = routes[path] {
            return try result.get()
        }
        if let fallback {
            return try fallback.get()
        }
        throw BridgeError.unreachable("no route for \(path)")
    }

    func postData(_ path: String, body: Data?, token: String?) async throws -> Data {
        guard let body else { throw BridgeError.unsupported(path) }
        posts.append(Post(path: path, body: body))
        return body
    }

    func delete(_ path: String, token: String?) async throws -> Data {
        throw BridgeError.unsupported(path)
    }

    func uploadFile(_ path: String, body: Data, filename: String, token: String?) async throws -> Data {
        throw BridgeError.unsupported(path)
    }

    func get<T: Decodable>(_ path: String, decoder: JSONDecoder) async throws -> T {
        try decoder.decode(T.self, from: try await getData(path, token: nil))
    }

    func post<T: Decodable>(_ path: String, body: Data?, decoder: JSONDecoder) async throws -> T {
        throw BridgeError.unsupported(path)
    }

    func stream(
        _ path: String,
        method: String,
        body: Data?,
        token: String?
    ) -> AsyncThrowingStream<SSEMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func health() async throws {}
}
