import XCTest
@testable import Garime

final class SessionsHomeKillTests: XCTestCase {
    private func process(_ json: String) throws -> TermAgentProcess {
        try JSONDecoder().decode(TermAgentProcess.self, from: Data(json.utf8))
    }

    func testMacSessionIsNotKillable() {
        XCTAssertFalse(SessionsHomeKill.killable(session: TerminalSessionList.mac))
        XCTAssertFalse(SessionsHomeKill.killable(session: TerminalSessionList.reserved))
        XCTAssertFalse(SessionsHomeKill.killable(session: "mac:qualquer"))
    }

    func testVMSessionIsKillable() {
        XCTAssertTrue(SessionsHomeKill.killable(session: "vm:mobile"))
        XCTAssertTrue(SessionsHomeKill.killable(session: "vm:claude"))
    }

    func testSessionAgentIsKillable() throws {
        let agent = try process(#"""
        {"host":"vm","agent":"claude","status":"working","project":"garime","session":"claude"}
        """#)
        XCTAssertEqual(agent.chatRef, .session("claude"))
        XCTAssertEqual(SessionsHomeKill.target(agent), "vm:claude")
    }

    func testPaneAgentIsNotKillable() throws {
        let agent = try process(#"""
        {"host":"mac","agent":"herdr","status":"idle","project":"garime","pane":"w1:p1"}
        """#)
        XCTAssertEqual(agent.chatRef, .pane(project: "garime", pane: "w1:p1"))
        XCTAssertNil(SessionsHomeKill.target(agent))
    }

    func testAgentWithoutTargetIsNotKillable() throws {
        let agent = try process(#"""
        {"host":"vm","agent":"pi","status":"idle","project":"garime"}
        """#)
        XCTAssertNil(SessionsHomeKill.target(agent))
    }

    func testPromotedSessionIsNotListedTwice() throws {
        let agent = try process(#"""
        {"host":"vm","agent":"claude","status":"working","project":"garime","session":"claude"}
        """#)
        XCTAssertEqual(
            SessionsHomeDisplay.rows(["vm:mobile", "vm:claude", "mac:mac"], agents: [agent]),
            ["vm:mobile", "mac:mac"]
        )
        XCTAssertEqual(
            SessionsHomeDisplay.rows(["vm:mobile", "vm:claude", "mac:mac"], agents: []),
            ["vm:mobile", "vm:claude", "mac:mac"]
        )
    }
}

final class SessionsHomeStartTests: XCTestCase {
    func testStartableExcludesMacAndEmptyLabel() {
        XCTAssertTrue(SessionsHomeStart.startable(session: "vm:mobile"))
        XCTAssertTrue(SessionsHomeStart.startable(session: "vm:claude"))
        XCTAssertFalse(SessionsHomeStart.startable(session: TerminalSessionList.mac))
        XCTAssertFalse(SessionsHomeStart.startable(session: "mac:qualquer"))
    }

    func testAgentsOffered() {
        XCTAssertEqual(SessionsHomeStart.agents, ["claude", "pi", "codex"])
    }

    func testNoticeOnlyOnFailure() {
        XCTAssertNil(SessionsHomeStart.notice(.ok))
        XCTAssertEqual(SessionsHomeStart.notice(.running), "já tem agente nessa sessão")
        XCTAssertEqual(SessionsHomeStart.notice(.failed), "falha ao iniciar agente")
    }
}

private final class FakeStartBridge: BridgeAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var bodies: [String] = []

    var postResult: Result<Data, Error> = .success(Data(#"{"ok":true}"#.utf8))

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    var sentBodies: [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    func getData(_ path: String, token: String?) async throws -> Data {
        throw BridgeError.unreachable(path)
    }

    func postData(_ path: String, body: Data?, token: String?) async throws -> Data {
        lock.lock()
        log.append(path)
        if let body { bodies.append(String(decoding: body, as: UTF8.self)) }
        let result = postResult
        lock.unlock()
        return try result.get()
    }

    func delete(_ path: String, token: String?) async throws -> Data {
        throw BridgeError.unsupported(path)
    }

    func uploadFile(_ path: String, body: Data, filename: String, token: String?) async throws -> Data {
        throw BridgeError.unsupported(path)
    }

    func get<T: Decodable>(_ path: String, decoder: JSONDecoder) async throws -> T {
        throw BridgeError.unsupported(path)
    }

    func post<T: Decodable>(_ path: String, body: Data?, decoder: JSONDecoder) async throws -> T {
        try decoder.decode(T.self, from: try await postData(path, body: body, token: nil))
    }

    func stream(_ path: String, method: String, body: Data?, token: String?) -> AsyncThrowingStream<SSEMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func health() async throws {}
}

@MainActor
final class SessionsHomeStartModelTests: XCTestCase {
    func testStartAgentPostsAgentBody() async {
        let fake = FakeStartBridge()
        let model = SessionsHomeModel(client: fake)
        let outcome = await model.startAgent("vm:mobile", agent: "pi")
        XCTAssertEqual(outcome, .ok)
        XCTAssertEqual(fake.calls, ["/term/agent-start?session=mobile"])
        XCTAssertEqual(fake.sentBodies, [#"{"agent":"pi"}"#])
    }

    func testAlreadyRunningIsReported() async {
        let fake = FakeStartBridge()
        fake.postResult = .failure(BridgeError.server(status: 409, code: "already_running"))
        let model = SessionsHomeModel(client: fake)
        let outcome = await model.startAgent("vm:mobile", agent: "claude")
        XCTAssertEqual(outcome, .running)
    }

    func testNoAttachIsNotReportedAsAlreadyRunning() async {
        let fake = FakeStartBridge()
        fake.postResult = .failure(BridgeError.server(status: 409, code: "no_attach"))
        let model = SessionsHomeModel(client: fake)
        let outcome = await model.startAgent("vm:mobile", agent: "claude")
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(outcome.flatMap(SessionsHomeStart.notice), "falha ao iniciar agente")
    }

    func testMissingEndpointIsFailure() async {
        let fake = FakeStartBridge()
        fake.postResult = .failure(BridgeError.server(status: 404, code: ""))
        let model = SessionsHomeModel(client: fake)
        let outcome = await model.startAgent("vm:mobile", agent: "codex")
        XCTAssertEqual(outcome, .failed)
    }

    func testSecondTapDuringFlightIsIgnored() async {
        let fake = GatedStartBridge()
        let model = SessionsHomeModel(client: fake)
        let first = Task { await model.startAgent("vm:mobile", agent: "claude") }
        await settle { fake.waiting }
        fake.gated = false
        let second = await model.startAgent("vm:mobile", agent: "claude")
        XCTAssertNil(second)
        XCTAssertEqual(fake.calls.count, 1)
        fake.open()
        let outcome = await first.value
        XCTAssertEqual(outcome, .ok)
    }

    func testStateIsReleasedAfterSuccess() async {
        let fake = GatedStartBridge()
        fake.gated = false
        let model = SessionsHomeModel(client: fake)
        let first = await model.startAgent("vm:mobile", agent: "claude")
        let second = await model.startAgent("vm:mobile", agent: "pi")
        XCTAssertEqual(first, .ok)
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(fake.calls.count, 2)
    }

    func testStateIsReleasedAfterError() async {
        let fake = GatedStartBridge()
        fake.gated = false
        fake.postResult = .failure(BridgeError.server(status: 500, code: ""))
        let model = SessionsHomeModel(client: fake)
        let first = await model.startAgent("vm:mobile", agent: "claude")
        let second = await model.startAgent("vm:mobile", agent: "claude")
        XCTAssertEqual(first, .failed)
        XCTAssertEqual(second, .failed)
        XCTAssertEqual(fake.calls.count, 2)
    }

    private func settle(_ until: () -> Bool) async {
        for _ in 0..<10_000 where !until() { await Task.yield() }
    }
}

private final class GatedStartBridge: BridgeAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var gate: CheckedContinuation<Void, Never>?

    var gated = true
    var postResult: Result<Data, Error> = .success(Data(#"{"ok":true}"#.utf8))

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    var waiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gate != nil
    }

    func open() {
        lock.lock()
        let pending = gate
        gate = nil
        lock.unlock()
        pending?.resume()
    }

    func getData(_ path: String, token: String?) async throws -> Data {
        throw BridgeError.unreachable(path)
    }

    func postData(_ path: String, body: Data?, token: String?) async throws -> Data {
        lock.lock()
        log.append(path)
        let result = postResult
        let hold = gated
        lock.unlock()
        if hold {
            await withCheckedContinuation { continuation in
                lock.lock()
                gate = continuation
                lock.unlock()
            }
        }
        return try result.get()
    }

    func delete(_ path: String, token: String?) async throws -> Data {
        throw BridgeError.unsupported(path)
    }

    func uploadFile(_ path: String, body: Data, filename: String, token: String?) async throws -> Data {
        throw BridgeError.unsupported(path)
    }

    func get<T: Decodable>(_ path: String, decoder: JSONDecoder) async throws -> T {
        throw BridgeError.unsupported(path)
    }

    func post<T: Decodable>(_ path: String, body: Data?, decoder: JSONDecoder) async throws -> T {
        try decoder.decode(T.self, from: try await postData(path, body: body, token: nil))
    }

    func stream(_ path: String, method: String, body: Data?, token: String?) -> AsyncThrowingStream<SSEMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func health() async throws {}
}
