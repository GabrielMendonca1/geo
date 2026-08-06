import XCTest
@testable import Garime

final class AgentCommandsDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> AgentCommandsPayload {
        try JSONDecoder().decode(AgentCommandsPayload.self, from: Data(json.utf8))
    }

    func testDecodesCommands() throws {
        let payload = try decode(#"""
        {"agent":"claude","commands":[
         {"name":"g-omni","description":"conduz tarefa","scope":"user"},
         {"name":"review","description":"","scope":"project"}
        ]}
        """#)
        XCTAssertEqual(payload.agent, "claude")
        XCTAssertEqual(payload.commands.map(\.name), ["g-omni", "review"])
        XCTAssertEqual(payload.commands[0].description, "conduz tarefa")
        XCTAssertEqual(payload.commands[0].scope, "user")
    }

    func testEmptyListDecodes() throws {
        XCTAssertTrue(try decode(#"{"agent":"codex","commands":[]}"#).commands.isEmpty)
    }

    func testMissingFieldsAreTolerated() throws {
        let payload = try decode(#"{"commands":[{"name":"solto"},{"description":"sem nome"},{"name":"  "}]}"#)
        XCTAssertEqual(payload.agent, "")
        XCTAssertEqual(payload.commands.map(\.name), ["solto"])
        XCTAssertEqual(payload.commands[0].description, "")
        XCTAssertEqual(payload.commands[0].scope, "")
    }

    func testMissingCommandsDecodesEmpty() throws {
        XCTAssertTrue(try decode(#"{"agent":"claude"}"#).commands.isEmpty)
    }
}

final class AgentCommandMenuTests: XCTestCase {
    private let commands = [
        AgentCommand(name: "g-omni", description: "conduz", scope: "user"),
        AgentCommand(name: "g-loop", description: "repete", scope: "user"),
        AgentCommand(name: "review", description: "revisa", scope: "project"),
    ]

    func testQueryOnlyWhenDraftStartsWithSlash() {
        XCTAssertEqual(AgentCommandMenu.query("/g-o"), "g-o")
        XCTAssertEqual(AgentCommandMenu.query("/"), "")
        XCTAssertNil(AgentCommandMenu.query("oi /g-omni"))
        XCTAssertNil(AgentCommandMenu.query(""))
    }

    func testQueryEndsAtWhitespace() {
        XCTAssertNil(AgentCommandMenu.query("/g-omni roda os testes"))
        XCTAssertNil(AgentCommandMenu.query("/g-omni "))
        XCTAssertNil(AgentCommandMenu.query("/g\nomni"))
    }

    func testFilterByPrefix() {
        XCTAssertEqual(AgentCommandMenu.filter(commands, query: "g-").map(\.name), ["g-omni", "g-loop"])
        XCTAssertEqual(AgentCommandMenu.filter(commands, query: "g-l").map(\.name), ["g-loop"])
        XCTAssertEqual(AgentCommandMenu.filter(commands, query: "REV").map(\.name), ["review"])
    }

    func testEmptyQueryKeepsEverythingAndMissIsEmpty() {
        XCTAssertEqual(AgentCommandMenu.filter(commands, query: "").count, 3)
        XCTAssertTrue(AgentCommandMenu.filter(commands, query: "zz").isEmpty)
        XCTAssertTrue(AgentCommandMenu.filter([], query: "g").isEmpty)
    }

    func testInsertionAddsTrailingSpace() {
        XCTAssertEqual(AgentCommandMenu.inserted("g-omni"), "/g-omni ")
    }
}

final class AgentUploadNameTests: XCTestCase {
    func testKeepsAllowedCharacters() {
        XCTAssertEqual(UploadName.sanitized("Foto_2026-08.jpg", fallback: "x"), "Foto_2026-08.jpg")
    }

    func testReplacesForbiddenCharacters() {
        XCTAssertEqual(UploadName.sanitized("meu arquivo (1).pdf", fallback: "x"), "meu_arquivo__1_.pdf")
        XCTAssertEqual(UploadName.sanitized("relatório final.txt", fallback: "x"), "relat_rio_final.txt")
    }

    func testStripsPathAndLeadingDots() {
        XCTAssertEqual(UploadName.sanitized("/tmp/../.oculto.txt", fallback: "x"), "oculto.txt")
    }

    func testClampsToEightyCharacters() {
        let long = String(repeating: "a", count: 200) + ".txt"
        let name = UploadName.sanitized(long, fallback: "x")
        XCTAssertEqual(name.count, 80)
        XCTAssertTrue(name.hasSuffix(".txt"))
    }

    func testFallbackWhenNothingSurvives() {
        XCTAssertEqual(UploadName.sanitized("...", fallback: "arquivo"), "arquivo")
        XCTAssertEqual(UploadName.sanitized("", fallback: "arquivo"), "arquivo")
    }
}

final class AgentUploadFailureTests: XCTestCase {
    func testMapsServerStatuses() {
        XCTAssertEqual(AgentUploadFailure.text(BridgeError.server(status: 413, code: "too_large")), "arquivo grande demais")
        XCTAssertEqual(AgentUploadFailure.text(BridgeError.server(status: 503, code: "unavailable")), "mac fora do ar")
        XCTAssertEqual(AgentUploadFailure.text(BridgeError.server(status: 500, code: "")), "upload falhou")
        XCTAssertEqual(AgentUploadFailure.text(BridgeError.unreachable("timeout")), "upload falhou")
    }
}

final class AgentComposerEndpointTests: XCTestCase {
    func testCommandsPathEncodesPaneColon() {
        XCTAssertEqual(
            BridgeEndpoint.termAgentCommands(target: .pane(project: "garime", pane: "w1:p3")).path,
            "/term/agent-commands?project=garime&pane=w1%3Ap3"
        )
    }

    func testUploadPathEncodesPaneColon() {
        XCTAssertEqual(
            BridgeEndpoint.termAgentUpload(target: .pane(project: "meu projeto", pane: "w1:p3")).path,
            "/term/agent-upload?project=meu%20projeto&pane=w1%3Ap3"
        )
    }
}

@MainActor
final class AgentComposerModelTests: XCTestCase {
    private let target = AgentChatTarget(project: "garime", pane: "w1:p3", agent: "claude")

    func testMissingEndpointLeavesMenuEmptyAndSilent() async {
        let fake = FakeComposerBridge()
        fake.getResult = .failure(BridgeError.server(status: 404, code: "not_found"))
        let model = AgentComposerModel(target: target, client: fake)
        await model.loadCommands()
        XCTAssertTrue(model.commands.isEmpty)
        XCTAssertTrue(model.notice.isEmpty)
    }

    func testFailedLoadIsNotRetriedPerKeystroke() async {
        let fake = FakeComposerBridge()
        fake.getResult = .failure(BridgeError.server(status: 404, code: "not_found"))
        let model = AgentComposerModel(target: target, client: fake)
        await model.loadCommands()
        await model.loadCommands()
        await model.loadCommands()
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("/term/agent-commands") }.count, 1)
        XCTAssertTrue(model.commands.isEmpty)
    }

    func testUploadRefusesFilesOverThirtyTwoMiB() async {
        let fake = FakeComposerBridge()
        fake.uploadResult = .success(Data(#"{"path":"/tmp/x"}"#.utf8))
        let model = AgentComposerModel(target: target, client: fake)
        let path = await model.upload(Data(count: AgentUploadLimit.maxBytes + 1), filename: "video.mov")
        XCTAssertNil(path)
        XCTAssertEqual(model.notice, "arquivo grande demais")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testCommandsAreFetchedOnceAndCached() async {
        let fake = FakeComposerBridge()
        fake.getResult = .success(Data(#"{"agent":"claude","commands":[{"name":"g-omni"}]}"#.utf8))
        let model = AgentComposerModel(target: target, client: fake)
        await model.loadCommands()
        await model.loadCommands()
        XCTAssertEqual(model.commands.map(\.name), ["g-omni"])
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("/term/agent-commands") }.count, 1)
    }

    func testUploadReturnsPathOnSuccess() async {
        let fake = FakeComposerBridge()
        fake.uploadResult = .success(Data(#"{"path":"/Users/biel/garime-uploads/foto.jpg"}"#.utf8))
        let model = AgentComposerModel(target: target, client: fake)
        let path = await model.upload(Data([1, 2, 3]), filename: "foto.jpg")
        XCTAssertEqual(path, "/Users/biel/garime-uploads/foto.jpg")
        XCTAssertTrue(model.notice.isEmpty)
    }

    func testUploadFailureExplainsItself() async {
        let fake = FakeComposerBridge()
        fake.uploadResult = .failure(BridgeError.server(status: 413, code: "too_large"))
        let model = AgentComposerModel(target: target, client: fake)
        let path = await model.upload(Data([1, 2, 3]), filename: "video.mov")
        XCTAssertNil(path)
        XCTAssertEqual(model.notice, "arquivo grande demais")
    }
}

final class AgentFileReadTests: XCTestCase {
    private func temp(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    func testReadsSmallFile() throws {
        let url = temp("nota.txt")
        try Data("oi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(AgentFileRead.read(url), .ok(Data("oi".utf8)))
    }

    func testRefusesFileOverCapWithoutReadingIt() throws {
        let url = temp("grande.mov")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(AgentUploadLimit.maxBytes + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(AgentFileRead.read(url), .tooLarge)
    }

    func testMissingFileFails() {
        XCTAssertEqual(AgentFileRead.read(temp("sumiu.txt")), .failed)
    }
}

final class DictationDraftTests: XCTestCase {
    func testEmptyTranscriptDoesNotTouchDraft() {
        XCTAssertNil(DictationDraft.merged(base: "oi", transcript: ""))
    }

    func testAppendsToBase() {
        XCTAssertEqual(DictationDraft.merged(base: "oi", transcript: "tudo bem"), "oi tudo bem")
        XCTAssertEqual(DictationDraft.merged(base: "", transcript: "tudo bem"), "tudo bem")
    }
}

@MainActor
final class AgentDictationModelTests: XCTestCase {
    func testFinalResultLandsInTranscriptAndStops() {
        let model = AgentDictationModel()
        model.handle(text: "oi", isFinal: true, failed: false)
        XCTAssertEqual(model.transcript, "oi")
        XCTAssertFalse(model.recording)
        XCTAssertTrue(model.notice.isEmpty)
    }

    func testPartialsAccumulateBeforeFinalCorrection() {
        let model = AgentDictationModel()
        model.handle(text: "roda os teste", isFinal: false, failed: false)
        XCTAssertEqual(model.transcript, "roda os teste")
        model.handle(text: "Roda os testes.", isFinal: true, failed: false)
        XCTAssertEqual(model.transcript, "Roda os testes.")
    }

    func testSilentFailureExplainsItself() {
        let model = AgentDictationModel()
        model.handle(text: nil, isFinal: false, failed: true)
        XCTAssertEqual(model.notice, "não entendi o áudio")
    }

    func testFailureAfterTextKeepsTextAndStaysSilent() {
        let model = AgentDictationModel()
        model.handle(text: "oi", isFinal: false, failed: false)
        model.handle(text: nil, isFinal: false, failed: true)
        XCTAssertEqual(model.transcript, "oi")
        XCTAssertTrue(model.notice.isEmpty)
    }
}

private final class FakeComposerBridge: BridgeAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var getResult: Result<Data, Error> = .failure(BridgeError.unreachable("unset"))
    var uploadResult: Result<Data, Error> = .failure(BridgeError.unreachable("unset"))

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func getData(_ path: String, token: String?) async throws -> Data {
        lock.lock()
        log.append(path)
        lock.unlock()
        return try getResult.get()
    }

    func postData(_ path: String, body: Data?, token: String?) async throws -> Data {
        throw BridgeError.unsupported(path)
    }

    func delete(_ path: String, token: String?) async throws -> Data {
        throw BridgeError.unsupported(path)
    }

    func uploadFile(_ path: String, body: Data, filename: String, token: String?) async throws -> Data {
        lock.lock()
        log.append(path)
        lock.unlock()
        return try uploadResult.get()
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
