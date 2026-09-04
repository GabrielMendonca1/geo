import XCTest
@testable import Garime

private final class FakeBridge: BridgeAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var routes: [String: Result<Data, Error>] = [:]

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func getData(_ path: String, token: String?) async throws -> Data {
        lock.lock()
        log.append(path)
        lock.unlock()
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
final class AgentHomeTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func liveFake() -> FakeBridge {
        let fake = FakeBridge()
        fake.routes = [
            "/term/health": .success(data(#"""
            {"ok":true,"mac_online":true,"agent":{"session":"garime-agent","running":true,"agent":"pi"}}
            """#)),
        ]
        return fake
    }

    func testHealthPathIsFixed() {
        XCTAssertEqual(BridgeEndpoint.termHealth.path, "/term/health")
    }

    func testChatTargetIsTheFixedInstance() {
        let target = GarimeAgent.target("")
        XCTAssertEqual(target.ref, .session("garime-agent"))
        XCTAssertEqual(target.agent, "pi")
        XCTAssertEqual(
            BridgeEndpoint.termAgentChat(target: target.ref, limit: 40).path,
            "/term/agent-chat?session=garime-agent&limit=40"
        )
        XCTAssertEqual(
            BridgeEndpoint.termAgentPrompt(target: target.ref).path,
            "/term/agent-prompt?session=garime-agent"
        )
    }

    func testSessionOverrideWins() {
        XCTAssertEqual(GarimeAgent.session("  outro  "), "outro")
        XCTAssertEqual(GarimeAgent.session("   "), "garime-agent")
    }

    func testHealthyRefreshLightsBothDots() async {
        var now = 0.0
        let model = AgentHomeModel(client: liveFake(), clock: { now += 0.25; return now })
        await model.refresh()

        XCTAssertTrue(model.reachable)
        XCTAssertTrue(model.macOnline)
        XCTAssertTrue(model.agentRunning)
        XCTAssertEqual(model.vmLevel, .healthy)
        XCTAssertEqual(model.macLevel, .healthy)
        XCTAssertEqual(model.latency, 250)
    }

    func testMacOfflineOnlyDimsTheMacDot() async {
        let fake = liveFake()
        fake.routes["/term/health"] = .success(data(#"{"ok":true,"mac_online":false,"agent":{"running":false}}"#))
        let model = AgentHomeModel(client: fake)
        await model.refresh()

        XCTAssertEqual(model.vmLevel, .healthy)
        XCTAssertEqual(model.macLevel, .failed)
        XCTAssertFalse(model.agentRunning)
        XCTAssertEqual(model.agentNote, "agente parado")
    }

    func testUnreachableBridgeKillsBothDots() async {
        let fake = liveFake()
        let model = AgentHomeModel(client: fake)
        await model.refresh()

        fake.routes = [:]
        await model.refresh()

        XCTAssertEqual(model.vmLevel, .failed)
        XCTAssertEqual(model.macLevel, .dormant)
        XCTAssertNil(model.latency)
        XCTAssertEqual(model.agentNote, "bridge fora do ar")
    }

    func testMissingAgentBlockDecodesAsStopped() async {
        let fake = liveFake()
        fake.routes["/term/health"] = .success(data(#"{"ok":true,"mac_online":true}"#))
        let model = AgentHomeModel(client: fake)
        await model.refresh()

        XCTAssertTrue(model.reachable)
        XCTAssertFalse(model.agentRunning)
    }

    func testHomeOnlyPollsHealth() async {
        let fake = liveFake()
        let model = AgentHomeModel(client: fake)
        await model.refresh()

        XCTAssertEqual(fake.calls, ["/term/health"])
    }
}
