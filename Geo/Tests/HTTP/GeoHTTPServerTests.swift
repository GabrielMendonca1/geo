import XCTest
@testable import Geo

@MainActor
final class GeoHTTPServerTests: XCTestCase {
    var server: GeoHTTPServer!
    var tokens: APITokenStore!
    var runtimeToken: String!
    var hookToken: String!
    var port: UInt16 = 0
    var bootstrapClearedCallers: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        tokens = APITokenStore(
            service: "geo-api-test-\(UUID().uuidString)",
            bootstrapService: "geo-api-bootstrap-test-\(UUID().uuidString)"
        )
        tokens.ensureBootstrapTokens()
        runtimeToken = tokens.readBootstrapRaw(callerId: APITokenStore.bootstrapRuntime)
        hookToken = tokens.readBootstrapRaw(callerId: APITokenStore.bootstrapHook)
        XCTAssertNotNil(runtimeToken, "runtime bootstrap token should exist")
        XCTAssertNotNil(hookToken, "hook bootstrap token should exist")

        let registry = MCPToolRegistry(tools: [])
        let blocks = FakeBlocksRepository()
        let router = GeoAPIRouter(registry: registry, tokens: tokens, blocks: blocks)
        server = GeoHTTPServer(router: router)
        try server.start()

        for _ in 0..<50 {
            if server.port != 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        port = server.port
        XCTAssertNotEqual(port, 0, "server should bind to a port")
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        _ = tokens.revoke(callerId: APITokenStore.bootstrapRuntime)
        _ = tokens.revoke(callerId: APITokenStore.bootstrapHook)
        tokens = nil
        try await super.tearDown()
    }

    func testBootstrapTokensExist() {
        let list = tokens.list()
        let ids = Set(list.map(\.callerId))
        XCTAssertTrue(ids.contains(APITokenStore.bootstrapRuntime))
        XCTAssertTrue(ids.contains(APITokenStore.bootstrapHook))
        let runtime = list.first { $0.callerId == APITokenStore.bootstrapRuntime }
        let hook = list.first { $0.callerId == APITokenStore.bootstrapHook }
        XCTAssertEqual(runtime?.scope, .readWriteDestructive)
        XCTAssertEqual(hook?.scope, .read)
    }

    func testValidateRoundtrip() {
        let validated = tokens.validate(rawToken: runtimeToken)
        XCTAssertNotNil(validated)
        XCTAssertEqual(validated?.callerId, APITokenStore.bootstrapRuntime)
        XCTAssertEqual(validated?.scope, .readWriteDestructive)

        XCTAssertNil(tokens.validate(rawToken: "garbage"))
    }

    func testScopeAllows() {
        XCTAssertTrue(TokenScope.readWriteDestructive.allows(.read))
        XCTAssertTrue(TokenScope.readWriteDestructive.allows(.readWrite))
        XCTAssertTrue(TokenScope.readWriteDestructive.allows(.readWriteDestructive))
        XCTAssertFalse(TokenScope.read.allows(.readWrite))
        XCTAssertFalse(TokenScope.readWrite.allows(.readWriteDestructive))
    }

    func testMissingAuthReturns401() async throws {
        let (status, _, headers) = try await httpGet("/v1/blocks/orphans", token: nil)
        XCTAssertEqual(status, 401)
        XCTAssertTrue((headers["www-authenticate"] ?? "").contains("Bearer"))
    }

    func testHookTokenCannotPost() async throws {
        let body = Data(#"{"title":"x"}"#.utf8)
        let (status, _, _) = try await httpRequest(method: "POST", path: "/v1/tasks", token: hookToken, body: body)
        XCTAssertEqual(status, 403)
    }

    func testRotatedTokenReturnsRotatedRealm() async throws {
        let stale = "stale-token-that-doesnt-exist"
        let (status, _, headers) = try await httpGet("/v1/blocks/orphans", token: stale)
        XCTAssertEqual(status, 401)
        XCTAssertTrue((headers["www-authenticate"] ?? "").contains("rotated"))
    }

    // MARK: helpers

    private func httpGet(_ path: String, token: String?) async throws -> (Int, Data, [String: String]) {
        try await httpRequest(method: "GET", path: path, token: token, body: nil)
    }

    private func httpRequest(method: String, path: String, token: String?, body: Data?) async throws -> (Int, Data, [String: String]) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: req)
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let key = k as? String, let val = v as? String { headers[key.lowercased()] = val }
        }
        return (http.statusCode, data, headers)
    }
}

private final class FakeBlocksRepository: BlocksRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[BlockEntity]> { AsyncStream { $0.finish() } }
    func search(matching query: String) async throws -> [BlockEntity] { [] }
    func list() async throws -> [BlockEntity] { [] }
    func create(title: String, markdown: String) async throws -> BlockEntity { throw RepositoryError.invalidInput }
    func update(id: String, markdown: String) async throws {}
    func delete(id: String) async throws {}
    func setTag(blockId: String, tagId: String?) async throws {}
    func setFullWidth(blockId: String, isFullWidth: Bool) async throws {}
    func setLayer(blockId: String, layer: BlockLayer) async throws {}
    func setType(blockId: String, type: BlockType) async throws {}
    func setStatus(blockId: String, status: String?) async throws {}
    func checkboxes(in blockId: String) async -> [BlockCheckbox] { [] }
    func toggleCheckbox(in blockId: String, lineNumber: Int) async throws {}
    func mutateFrontmatter(blockId: String, merge: [String: AnyCodableValue]) async throws -> Int { 0 }
    @MainActor func saveSync(id: String, markdown: String) -> Bool { false }
}
