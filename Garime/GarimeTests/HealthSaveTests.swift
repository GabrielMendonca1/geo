import Foundation
import XCTest
@testable import Garime

final class HealthSaveTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthSaveURLProtocol.self]
        session = URLSession(configuration: configuration)
        HealthSaveURLProtocol.reset()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        HealthSaveURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    func testConfirmedSeriesAreAppliedLocallyAndNextExerciseKeepsThemWithoutGET() async throws {
        HealthSaveURLProtocol.handler = Self.successfulHandler
        let model = makeModel()
        await model.reload()
        let initialGETs = HealthSaveURLProtocol.requests.filter { $0.httpMethod == "GET" }.count

        try await model.saveExercise(
            exerciseId: "supino",
            sets: [VitalsLogSet(reps: 10, kg: 40)]
        )
        try await model.saveExercise(
            exerciseId: "remada",
            sets: [VitalsLogSet(reps: 12, kg: 35)]
        )

        XCTAssertEqual(HealthSaveURLProtocol.requests.filter { $0.httpMethod == "GET" }.count, initialGETs)
        let posts = HealthSaveURLProtocol.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        let secondLog = try JSONDecoder().decode(VitalsLog.self, from: try XCTUnwrap(posts.last?.httpBody))
        XCTAssertEqual(secondLog.exercises.map(\.id), ["supino", "remada"])
        XCTAssertEqual(model.todayLog?.exercises.map(\.id), ["supino", "remada"])
    }

    @MainActor
    func testRefreshFailureDoesNotEraseConfirmedLog() async throws {
        var failLogs = false
        HealthSaveURLProtocol.handler = { request in
            if request.url?.path == BridgeEndpoint.vitalsLogs.path, failLogs {
                return (500, Data())
            }
            return Self.successfulHandler(request)
        }
        let model = makeModel()
        await model.reload()
        try await model.saveExercise(
            exerciseId: "supino",
            sets: [VitalsLogSet(reps: 8, kg: 45)]
        )
        failLogs = true

        await model.reload()

        XCTAssertEqual(model.todayLog?.exercises.first?.id, "supino")
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testSaveWithoutTargetThrowsExplicitErrorAndDoesNotPOST() async throws {
        HealthSaveURLProtocol.handler = { request in
            if request.url?.path == BridgeEndpoint.vitalsLogs.path {
                return (200, Data("[]".utf8))
            }
            return (404, Data())
        }
        let model = makeModel()

        do {
            try await model.saveExercise(
                exerciseId: "supino",
                sets: [VitalsLogSet(reps: 10, kg: 40)]
            )
            XCTFail("save without a current plan/session must fail")
        } catch {
            XCTAssertEqual(error as? HealthSaveError, .targetUnavailable)
        }
        XCTAssertFalse(HealthSaveURLProtocol.requests.contains { $0.httpMethod == "POST" })
    }

    @MainActor
    func testConcurrentWholeDaySaveIsRejected() async throws {
        let postStarted = expectation(description: "first POST started")
        HealthSaveURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                postStarted.fulfill()
                Thread.sleep(forTimeInterval: 0.25)
            }
            return Self.successfulHandler(request)
        }
        let model = makeModel()
        await model.reload()

        let first = Task {
            try await model.saveExercise(
                exerciseId: "supino",
                sets: [VitalsLogSet(reps: 10, kg: 40)]
            )
        }
        await fulfillment(of: [postStarted], timeout: 1)

        do {
            try await model.saveNote(note: "concorrente")
            XCTFail("a concurrent whole-day save must be rejected")
        } catch {
            XCTAssertEqual(error as? HealthSaveError, .saveInProgress)
        }
        try await first.value
        XCTAssertEqual(HealthSaveURLProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    @MainActor
    func testReturningToWorkoutSameDayDoesNotRefetchOrLosePlanOffline() async throws {
        HealthSaveURLProtocol.handler = Self.successfulHandler
        let model = makeModel()
        await model.reload()
        XCTAssertNotNil(model.todaySession)
        let requests = HealthSaveURLProtocol.requests.count
        HealthSaveURLProtocol.handler = { _ in (500, Data()) }
        await model.refreshIfDayChanged()
        XCTAssertEqual(HealthSaveURLProtocol.requests.count, requests)
        XCTAssertTrue(model.isPlanPrimary)
        XCTAssertNotNil(model.todaySession)
    }

    @MainActor
    func testFailedPOSTDoesNotMarkSeriesSavedAndCanRetry() async throws {
        var failPOST = true
        HealthSaveURLProtocol.handler = { request in
            if request.httpMethod == "POST", failPOST { return (500, Data()) }
            return Self.successfulHandler(request)
        }
        let model = makeModel()
        await model.reload()
        let sets = [VitalsLogSet(reps: 12, kg: 0)]
        do {
            try await model.saveExercise(exerciseId: "supino", sets: sets)
            XCTFail("a rejected POST cannot report success")
        } catch {}
        XCTAssertNil(model.todayEntry(for: "supino"))
        failPOST = false
        try await model.saveExercise(exerciseId: "supino", sets: sets)
        XCTAssertEqual(model.todayEntry(for: "supino")?.sets.first?.kg, 0)
        XCTAssertEqual(model.todayEntry(for: "supino")?.sets.first?.reps, 12)
    }

    @MainActor
    func testSheetFromPreviousDayCannotWriteTodaysLog() async throws {
        HealthSaveURLProtocol.handler = Self.successfulHandler
        let model = makeModel()
        await model.reload()
        do {
            try await model.saveExercise(
                exerciseId: "supino", sets: [VitalsLogSet(reps: 10, kg: 0)], expectedDay: "2026-08-23"
            )
            XCTFail("a stale workout sheet must not save into a new day")
        } catch {
            XCTAssertEqual(error as? HealthSaveError, .dayChanged)
        }
        XCTAssertFalse(HealthSaveURLProtocol.requests.contains { $0.httpMethod == "POST" })
    }

    @MainActor
    private func makeModel() -> HealthViewModel {
        let bridge = HealthSaveSessionBridge(session: session)
        let date = ISO8601DateFormatter().date(from: "2026-08-24T12:00:00Z")!
        return HealthViewModel(
            repository: BridgeVitalsRepository(client: bridge),
            trainingRepository: BridgeTrainingRepository(client: bridge),
            clock: TrainingClock(timeZone: TimeZone(secondsFromGMT: 0)!),
            now: { date }
        )
    }

    private static func successfulHandler(_ request: URLRequest) -> (Int, Data) {
        switch request.url?.path {
        case "/vitals/plan":
            return (200, planData)
        case BridgeEndpoint.vitalsProtocol.path:
            return (200, Data(#"{"id":"legacy","name":"Legacy","sessions":[]}"#.utf8))
        case BridgeEndpoint.vitalsState.path:
            return (404, Data())
        case BridgeEndpoint.vitalsLogs.path:
            return (200, Data("[]".utf8))
        case BridgeEndpoint.vitalsLog.path:
            return (200, request.httpBody ?? Data())
        default:
            return (404, Data())
        }
    }

    private static let planData = Data(#"""
    {"schema":"vitals.plan/1","id":"plan-2026-W35.r1","week":"2026-W35","revision":1,
     "frozenAt":"2026-08-24T00:00:00Z",
     "source":{"catalogId":"catalog","catalogVersion":1,"blocks":[],"generator":"conversation"},
     "days":[
       {"date":"2026-08-24","label":"Treino","rest":false,"items":[
         {"exerciseId":"supino","name":"Supino","muscles":["chest"],"sets":[[8,12]],"restSec":60},
         {"exerciseId":"remada","name":"Remada","muscles":["upper-back"],"sets":[[8,12]],"restSec":60}
       ]},
       {"date":"2026-08-25","label":"Descanso","rest":true,"items":[]},
       {"date":"2026-08-26","label":"Descanso","rest":true,"items":[]},
       {"date":"2026-08-27","label":"Descanso","rest":true,"items":[]},
       {"date":"2026-08-28","label":"Descanso","rest":true,"items":[]},
       {"date":"2026-08-29","label":"Descanso","rest":true,"items":[]},
       {"date":"2026-08-30","label":"Descanso","rest":true,"items":[]}
     ]}
    """#.utf8)
}

private final class HealthSaveURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    private static let lock = NSLock()
    private static var storedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    static func reset() {
        lock.withLock { storedRequests = [] }
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession may expose a POST body as a stream inside URLProtocol.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
            captured.httpBody = body
        }
        Self.lock.withLock { Self.storedRequests.append(captured) }
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(captured)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct HealthSaveSessionBridge: BridgeAPI, @unchecked Sendable {
    let session: URLSession

    func getData(_ path: String, token: String?) async throws -> Data {
        try await send(path: path, method: "GET", body: nil)
    }

    func postData(_ path: String, body: Data?, token: String?) async throws -> Data {
        try await send(path: path, method: "POST", body: body)
    }

    func delete(_ path: String, token: String?) async throws -> Data { throw BridgeError.unsupported(path) }
    func uploadFile(_ path: String, body: Data, filename: String, token: String?) async throws -> Data {
        throw BridgeError.unsupported(path)
    }
    func get<T: Decodable>(_ path: String, decoder: JSONDecoder) async throws -> T {
        try decoder.decode(T.self, from: try await getData(path, token: nil))
    }
    func post<T: Decodable>(_ path: String, body: Data?, decoder: JSONDecoder) async throws -> T {
        try decoder.decode(T.self, from: try await postData(path, body: body, token: nil))
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

    private func send(path: String, method: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://health-save.test\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.unreachable("invalid response") }
        guard (200..<300).contains(http.statusCode) else {
            throw BridgeError.server(status: http.statusCode, code: "test")
        }
        return data
    }
}
