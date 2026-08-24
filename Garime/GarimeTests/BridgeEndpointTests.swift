import XCTest
@testable import Garime

final class BridgeEndpointTests: XCTestCase {
    func testHealthPathIsCorrect() {
        XCTAssertEqual(BridgeEndpoint.health.path, "/health")
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
        XCTAssertNil(catalog)

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
}

private final class FakeTrainingBridge: BridgeAPI, @unchecked Sendable {
    let routes: [String: Result<Data, Error>]
    let fallback: Result<Data, Error>?

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
        throw BridgeError.unsupported(path)
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
