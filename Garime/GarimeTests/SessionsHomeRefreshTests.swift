import XCTest
@testable import Garime

private final class FakeBridge: BridgeAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var routes: [String: Result<Data, Error>] = [:]
    var delay: UInt64 = 0

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func count(_ prefix: String) -> Int {
        calls.filter { $0.hasPrefix(prefix) }.count
    }

    func getData(_ path: String, token: String?) async throws -> Data {
        lock.lock()
        log.append(path)
        lock.unlock()
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        guard let key = routes.keys.sorted(by: { $0.count > $1.count }).first(where: { path.hasPrefix($0) }) else {
            throw BridgeError.unreachable("no route for \(path)")
        }
        return try routes[key]!.get()
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

    func stream(_ path: String, method: String, body: Data?, token: String?) -> AsyncThrowingStream<SSEMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func health() async throws {}
}

@MainActor
final class SessionsHomeRefreshTests: XCTestCase {
    private let names = ["vm:mobile", "mac:mac"]

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func loadedFake() -> FakeBridge {
        let fake = FakeBridge()
        fake.routes = [
            "/term/list": .success(data(#"{"sessions":["mobile","mac"]}"#)),
            "/term/agents": .success(data(#"""
            {"units":[{"name":"garime-wa","active":true,"since":""}],"mac_online":true,
             "agents":[{"host":"mac","agent":"claude","status":"working","project":"garime","pane":"w1:p1"}]}
            """#)),
            "/term/preview": .success(data(#"{"text":"hello"}"#)),
        ]
        return fake
    }

    func testFailedCycleKeepsLastGoodData() async {
        let fake = loadedFake()
        let model = SessionsHomeModel(client: fake)
        await model.refresh(names)

        XCTAssertEqual(model.previews["vm:mobile"], "hello")
        XCTAssertEqual(model.agents.count, 1)
        XCTAssertEqual(model.units.count, 1)
        XCTAssertTrue(model.macOnline)
        XCTAssertTrue(model.reachable)

        fake.routes = [:]
        await model.refresh(names)

        XCTAssertEqual(model.previews["vm:mobile"], "hello")
        XCTAssertEqual(model.previews["mac:mac"], "hello")
        XCTAssertEqual(model.agents.count, 1)
        XCTAssertEqual(model.units.count, 1)
        XCTAssertTrue(model.macOnline)
        XCTAssertEqual(model.serverSessions, ["mobile", "mac"])
        XCTAssertFalse(model.reachable)
    }

    func testServiceUnavailableIsNotAnEmptyList() async {
        let fake = loadedFake()
        let model = SessionsHomeModel(client: fake)
        await model.refresh(names)

        fake.routes["/term/agents"] = .failure(BridgeError.server(status: 503, code: "unavailable"))
        await model.refresh(names)

        XCTAssertEqual(model.agents.count, 1)
        XCTAssertEqual(model.units.count, 1)
        XCTAssertTrue(model.macOnline)
        XCTAssertTrue(model.reachable)
    }

    func testGoodResponseReplacesData() async {
        let fake = loadedFake()
        let model = SessionsHomeModel(client: fake)
        await model.refresh(names)

        fake.routes["/term/preview"] = .success(data(#"{"text":"\u001b[31mnovo\u001b[0m"}"#))
        fake.routes["/term/agents"] = .success(data(#"{"units":[],"mac_online":false,"agents":[]}"#))
        await model.refresh(names)

        XCTAssertEqual(model.previews["vm:mobile"], "novo")
        XCTAssertTrue(model.agents.isEmpty)
        XCTAssertTrue(model.units.isEmpty)
        XCTAssertFalse(model.macOnline)
        XCTAssertTrue(model.reachable)
    }

    func testEmptyAgentListFromHealthyBridgeStillClears() async {
        let fake = loadedFake()
        let model = SessionsHomeModel(client: fake)
        await model.refresh(names)
        fake.routes["/term/agents"] = .success(data(#"{"units":[],"mac_online":false}"#))
        await model.refresh(names)
        XCTAssertTrue(model.agents.isEmpty)
    }

    func testTickerSkipsPreviewsBetweenCadenceWindows() async {
        let fake = loadedFake()
        let model = SessionsHomeModel(client: fake)
        for _ in 0..<SessionsHomeModel.previewEveryNCycles {
            await model.refresh(names, force: false)
        }
        XCTAssertEqual(fake.count("/term/list"), SessionsHomeModel.previewEveryNCycles)
        XCTAssertEqual(fake.count("/term/preview"), names.count)

        await model.refresh(names, force: false)
        XCTAssertEqual(fake.count("/term/preview"), names.count * 2)
    }

    func testForcedRefreshAlwaysFetchesPreviews() async {
        let fake = loadedFake()
        let model = SessionsHomeModel(client: fake)
        await model.refresh(names)
        await model.refresh(names)
        XCTAssertEqual(fake.count("/term/preview"), names.count * 2)
    }

    func testConcurrentRefreshDoesNotStack() async {
        let fake = loadedFake()
        fake.delay = 30_000_000
        let model = SessionsHomeModel(client: fake)
        async let first: Void = model.refresh(names, force: false)
        async let second: Void = model.refresh(names, force: false)
        _ = await (first, second)
        XCTAssertEqual(fake.count("/term/list"), 1)
    }

    func testForcedRefreshDuringCycleIsCoalescedIntoOneExtraPass() async {
        let fake = loadedFake()
        fake.delay = 30_000_000
        let model = SessionsHomeModel(client: fake)
        async let first: Void = model.refresh(names, force: false)
        async let second: Void = model.refresh(names, force: true)
        async let third: Void = model.refresh(names, force: true)
        _ = await (first, second, third)
        XCTAssertEqual(fake.count("/term/list"), 2)
    }
}
