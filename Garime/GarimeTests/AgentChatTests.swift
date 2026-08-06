import XCTest
@testable import Garime

private final class FakeChatBridge: BridgeAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var bodies: [Data] = []

    var getResult: Result<Data, Error> = .failure(BridgeError.unreachable("unset"))
    var postResult: Result<Data, Error> = .success(Data(#"{"ok":true}"#.utf8))

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    var sentBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    func getData(_ path: String, token: String?) async throws -> Data {
        lock.lock()
        log.append(path)
        lock.unlock()
        return try getResult.get()
    }

    func postData(_ path: String, body: Data?, token: String?) async throws -> Data {
        lock.lock()
        log.append(path)
        if let body { bodies.append(body) }
        lock.unlock()
        return try postResult.get()
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
        try decoder.decode(T.self, from: try await postData(path, body: body, token: nil))
    }

    func stream(_ path: String, method: String, body: Data?, token: String?) -> AsyncThrowingStream<SSEMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func health() async throws {}
}

final class AgentChatDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> AgentChatPayload {
        try JSONDecoder().decode(AgentChatPayload.self, from: Data(json.utf8))
    }

    func testDecodesRolesToolsAndTruncation() throws {
        let payload = try decode(#"""
        {"agent":"claude","status":"working","messages":[
         {"role":"user","text":"roda os testes","ts":"2026-08-05T02:10:01"},
         {"role":"assistant","text":"51 verdes","ts":"2026-08-05T02:10:05","truncated":true},
         {"role":"tool","tool":"Bash","ts":"2026-08-05T02:10:06"}
        ]}
        """#)

        XCTAssertEqual(payload.agent, "claude")
        XCTAssertEqual(payload.status, "working")
        XCTAssertEqual(payload.messages.count, 3)
        XCTAssertEqual(payload.messages[0].role, .user)
        XCTAssertEqual(payload.messages[1].role, .assistant)
        XCTAssertTrue(payload.messages[1].truncated)
        XCTAssertFalse(payload.messages[0].truncated)
        XCTAssertEqual(payload.messages[2].role, .tool)
        XCTAssertEqual(payload.messages[2].tool, "Bash")
        XCTAssertTrue(payload.messages[2].text.isEmpty)
    }

    func testUnknownRoleIsDropped() throws {
        let payload = try decode(#"""
        {"agent":"claude","status":"idle","messages":[
         {"role":"system","text":"ignora"},
         {"role":"assistant","text":"ok"}
        ]}
        """#)
        XCTAssertEqual(payload.messages.count, 1)
        XCTAssertEqual(payload.messages[0].text, "ok")
    }

    func testMissingMessagesDecodesEmpty() throws {
        let payload = try decode(#"{"agent":"codex","status":"idle"}"#)
        XCTAssertTrue(payload.messages.isEmpty)
        XCTAssertEqual(payload.agent, "codex")
    }

    func testMessageIDsAreUnique() throws {
        let payload = try decode(#"""
        {"agent":"claude","status":"idle","messages":[
         {"role":"user","text":"oi","ts":"t"},
         {"role":"user","text":"oi","ts":"t"}
        ]}
        """#)
        XCTAssertEqual(Set(payload.messages.map(\.id)).count, 2)
    }

    func testToolsGroupIntoOneChipRow() throws {
        let payload = try decode(#"""
        {"agent":"claude","status":"working","messages":[
         {"role":"user","text":"vai"},
         {"role":"tool","tool":"Read"},
         {"role":"tool","tool":"Bash"},
         {"role":"assistant","text":"pronto"}
        ]}
        """#)
        let items = AgentChatFeed.items(payload.messages)
        XCTAssertEqual(items.count, 3)
        guard case .tools(_, let names) = items[1] else { return XCTFail("expected tool chips") }
        XCTAssertEqual(names, ["Read", "Bash"])
    }
}

final class AgentChatMarkupTests: XCTestCase {
    func testPlainTextStaysOneProseChunk() {
        XCTAssertEqual(AgentChatMarkup.chunks("sem marcação nenhuma aqui"), [.prose("sem marcação nenhuma aqui")])
    }

    func testFencedBlockSplitsProseAndCode() {
        let raw = "olha:\n```swift\nlet a = 1\nlet b = 2\n```\npronto"
        XCTAssertEqual(AgentChatMarkup.chunks(raw), [
            .prose("olha:"),
            .code("let a = 1\nlet b = 2"),
            .prose("pronto"),
        ])
    }

    func testUnclosedFenceKeepsRemainderAsCode() {
        XCTAssertEqual(AgentChatMarkup.chunks("roda:\n```\nmake test"), [
            .prose("roda:"),
            .code("make test"),
        ])
    }

    func testEmptyBlockIsDropped() {
        XCTAssertEqual(AgentChatMarkup.chunks("antes\n```\n```\ndepois"), [
            .prose("antes"),
            .prose("depois"),
        ])
    }

    func testOnlyEmptyBlockYieldsNothing() {
        XCTAssertTrue(AgentChatMarkup.chunks("```\n```").isEmpty)
    }

    func testInlineCodeSplitsSpans() {
        XCTAssertEqual(AgentChatMarkup.spans("usa `git status` agora"), [
            .text("usa "),
            .code("git status"),
            .text(" agora"),
        ])
    }

    func testUnpairedBacktickStaysLiteral() {
        XCTAssertEqual(AgentChatMarkup.spans("um ` solto"), [.text("um ` solto")])
    }

    func testTextWithoutMarkupIsOneSpan() {
        XCTAssertEqual(AgentChatMarkup.spans("nada aqui"), [.text("nada aqui")])
    }

    func testCodeExtractionJoinsBlocks() {
        let raw = "a\n```\num\n```\nb\n```\ndois\n```"
        XCTAssertEqual(AgentChatMarkup.code(in: raw), "um\n\ndois")
        XCTAssertTrue(AgentChatMarkup.code(in: "só texto").isEmpty)
    }
}

final class AgentChatClockTests: XCTestCase {
    func testParsesBridgeTimestamp() {
        XCTAssertNotNil(AgentChatClock.date("2026-08-05T02:10:01"))
        XCTAssertNotNil(AgentChatClock.date("2026-08-05T02:10:01Z"))
        XCTAssertNil(AgentChatClock.date(""))
        XCTAssertNil(AgentChatClock.date("agora"))
    }

    func testLabelUsesHourOnSameDay() {
        let date = AgentChatClock.date("2026-08-05T14:07:00")!
        XCTAssertEqual(AgentChatClock.label("2026-08-05T14:07:00", now: date), "14:07")
        let other = AgentChatClock.date("2026-08-06T09:00:00")!
        XCTAssertEqual(AgentChatClock.label("2026-08-05T14:07:00", now: other), "05/08 14:07")
    }

    func testLabelIsEmptyForGarbage() {
        XCTAssertEqual(AgentChatClock.label("nada"), "")
    }

    func testStampsOnlyOnTimeGaps() {
        let messages = [
            AgentChatMessage(id: "1", role: .user, text: "a", tool: "", truncated: false, ts: "2026-08-05T02:10:00"),
            AgentChatMessage(id: "2", role: .assistant, text: "b", tool: "", truncated: false, ts: "2026-08-05T02:12:00"),
            AgentChatMessage(id: "3", role: .user, text: "c", tool: "", truncated: false, ts: "2026-08-05T03:00:00"),
        ]
        let items = AgentChatFeed.items(messages)
        XCTAssertEqual(items.count, 5)
        guard case .stamp(_, let first) = items[0], case .stamp(_, let second) = items[3] else {
            return XCTFail("expected two stamps")
        }
        XCTAssertEqual(first, "2026-08-05T02:10:00")
        XCTAssertEqual(second, "2026-08-05T03:00:00")
    }

    func testMessagesWithoutTimestampGetNoStamp() {
        let messages = [
            AgentChatMessage(id: "1", role: .user, text: "a", tool: "", truncated: false),
            AgentChatMessage(id: "2", role: .assistant, text: "b", tool: "", truncated: false),
        ]
        XCTAssertEqual(AgentChatFeed.items(messages).count, 2)
    }
}

final class AgentChatEmptyTests: XCTestCase {
    func testStates() {
        XCTAssertEqual(AgentChatEmpty.text(loaded: false, reachable: true, noAgent: false), "carregando…")
        XCTAssertEqual(AgentChatEmpty.text(loaded: false, reachable: false, noAgent: false), "sem conexão com o mac")
        XCTAssertEqual(AgentChatEmpty.text(loaded: true, reachable: true, noAgent: true), "esse agente não existe mais")
        XCTAssertEqual(AgentChatEmpty.text(loaded: true, reachable: true, noAgent: false), "sem mensagens ainda")
    }
}

final class AgentChatEndpointTests: XCTestCase {
    func testChatPathEncodesPaneColon() {
        XCTAssertEqual(
            BridgeEndpoint.termAgentChat(target: .pane(project: "garime", pane: "w1:p3"), limit: 40).path,
            "/term/agent-chat?project=garime&pane=w1%3Ap3&limit=40"
        )
    }

    func testChatPathClampsLimit() {
        XCTAssertEqual(
            BridgeEndpoint.termAgentChat(target: .pane(project: "g", pane: "w1:p1"), limit: 900).path,
            "/term/agent-chat?project=g&pane=w1%3Ap1&limit=200"
        )
    }

    func testPromptPathEncodesPaneColon() {
        XCTAssertEqual(
            BridgeEndpoint.termAgentPrompt(target: .pane(project: "meu projeto", pane: "w1:p3")).path,
            "/term/agent-prompt?project=meu%20projeto&pane=w1%3Ap3"
        )
    }
}

@MainActor
final class AgentChatModelTests: XCTestCase {
    private let target = AgentChatTarget(project: "garime", pane: "w1:p3", agent: "claude", status: "idle", title: "chat")

    private func loaded(_ fake: FakeChatBridge) -> FakeChatBridge {
        fake.getResult = .success(Data(#"""
        {"agent":"claude","status":"working","messages":[
         {"role":"user","text":"roda os testes","ts":"1"},
         {"role":"assistant","text":"51 verdes","ts":"2"}
        ]}
        """#.utf8))
        return fake
    }

    func testFailureKeepsMessages() async {
        let fake = loaded(FakeChatBridge())
        let model = AgentChatModel(target: target, client: fake)
        await model.refresh()
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertTrue(model.reachable)

        fake.getResult = .failure(BridgeError.unreachable("timeout"))
        await model.refresh()
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertFalse(model.reachable)
    }

    func testUnavailableKeepsMessages() async {
        let fake = loaded(FakeChatBridge())
        let model = AgentChatModel(target: target, client: fake)
        await model.refresh()

        fake.getResult = .failure(BridgeError.server(status: 503, code: "unavailable"))
        await model.refresh()
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertFalse(model.reachable)
    }

    func testNoAgentIsReachableAndFlagged() async {
        let fake = FakeChatBridge()
        fake.getResult = .failure(BridgeError.server(status: 404, code: "no_agent"))
        let model = AgentChatModel(target: target, client: fake)
        await model.refresh()
        XCTAssertTrue(model.reachable)
        XCTAssertTrue(model.noAgent)
    }

    func testGoodResponseReplacesMessages() async {
        let fake = loaded(FakeChatBridge())
        let model = AgentChatModel(target: target, client: fake)
        await model.refresh()

        fake.getResult = .success(Data(#"{"agent":"claude","status":"idle","messages":[]}"#.utf8))
        await model.refresh()
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.status, "idle")
        XCTAssertFalse(model.isWorking)
    }

    func testFailedSendKeepsOptimisticMessageAndRetryWorks() async {
        let fake = loaded(FakeChatBridge())
        let model = AgentChatModel(target: target, client: fake)
        await model.refresh()

        fake.postResult = .failure(BridgeError.server(status: 503, code: "unavailable"))
        await model.send("mais um")

        XCTAssertEqual(model.messages.count, 3)
        XCTAssertEqual(model.messages.last?.text, "mais um")
        XCTAssertTrue(model.messages.last?.failed == true)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(fake.sentBodies.map { String(decoding: $0, as: UTF8.self) }, ["mais um"])

        fake.postResult = .success(Data(#"{"ok":true}"#.utf8))
        let id = model.messages.last!.id
        await model.retry(id)
        XCTAssertTrue(model.messages.last?.failed == false)
    }

    func testOptimisticMessageIsReplacedWhenServerEchoesIt() async {
        let fake = loaded(FakeChatBridge())
        let model = AgentChatModel(target: target, client: fake)
        await model.refresh()

        fake.getResult = .success(Data(#"""
        {"agent":"claude","status":"working","messages":[
         {"role":"user","text":"roda os testes","ts":"1"},
         {"role":"assistant","text":"51 verdes","ts":"2"},
         {"role":"user","text":"mais um","ts":"3"}
        ]}
        """#.utf8))
        await model.send("mais um")

        XCTAssertEqual(model.messages.count, 3)
        XCTAssertFalse(model.messages.contains { $0.optimistic })
    }

    func testBlankPromptIsNotSent() async {
        let fake = loaded(FakeChatBridge())
        let model = AgentChatModel(target: target, client: fake)
        await model.send("   \n ")
        XCTAssertTrue(model.sentNothing(fake))
    }

    func testPollIntervalTracksStatus() async {
        let fake = loaded(FakeChatBridge())
        let model = AgentChatModel(target: target, client: fake)
        await model.refresh()
        XCTAssertTrue(model.isWorking)
        XCTAssertEqual(model.pollInterval, AgentChatModel.workingInterval)

        fake.getResult = .success(Data(#"{"agent":"claude","status":"idle","messages":[]}"#.utf8))
        await model.refresh()
        XCTAssertEqual(model.pollInterval, AgentChatModel.restingInterval)
    }
}

@MainActor
private extension AgentChatModel {
    func sentNothing(_ fake: FakeChatBridge) -> Bool {
        !fake.calls.contains { $0.hasPrefix("/term/agent-prompt") }
    }
}
