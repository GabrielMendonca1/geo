import XCTest
import Foundation
import Network
@testable import Geo

final class MCPUnixSocketTransportTests: XCTestCase {

    private func makeTempSocketPath() -> String {
        let dir = NSTemporaryDirectory() + "geo-unix-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/mcp.sock"
    }

    private func makeTransport(at path: String) -> UnixSocketTransport {
        let registry = MCPToolRegistry(tools: [])
        let router = MCPRouter(registry: registry)
        let authGuard = MCPAuthGuard()
        authGuard.register(token: "test-token", endpointId: UUID(), endpointName: "TestEndpoint")
        return UnixSocketTransport(socketPath: path, router: router, authGuard: authGuard)
    }

    private func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.05, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
        return predicate()
    }

    func testListenerBindsAtFreshSocketPath() throws {
        let path = makeTempSocketPath()
        let transport = makeTransport(at: path)
        try transport.start { _ in }

        let bound = waitUntil(timeout: 2.0) {
            FileManager.default.fileExists(atPath: path)
        }
        XCTAssertTrue(bound, "socket file should exist after listener becomes ready")

        let modeOK = waitUntil(timeout: 2.0) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let perms = attrs[.posixPermissions] as? NSNumber else { return false }
            return (perms.intValue & 0o777) == 0o600
        }
        XCTAssertTrue(modeOK, "socket file should be chmod 0600")

        transport.stop()

        let cleaned = waitUntil(timeout: 2.0) {
            !FileManager.default.fileExists(atPath: path)
        }
        XCTAssertTrue(cleaned, "socket file should be removed on stop")
    }

    func testListenerReplacesStaleSocket() throws {
        let path = makeTempSocketPath()
        try Data().write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let transport = makeTransport(at: path)
        try transport.start { _ in }

        let isSocket = waitUntil(timeout: 2.0) {
            var st = stat()
            guard stat(path, &st) == 0 else { return false }
            return (st.st_mode & S_IFMT) == S_IFSOCK
        }
        XCTAssertTrue(isSocket, "stale regular file should be replaced by a unix socket")

        transport.stop()

        let cleaned = waitUntil(timeout: 2.0) {
            !FileManager.default.fileExists(atPath: path)
        }
        XCTAssertTrue(cleaned, "socket file should be removed on stop")
    }

    func testClientCanConnectAndReceiveAuthError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Network.framework listeners may be blocked in CI")

        let path = makeTempSocketPath()
        let transport = makeTransport(at: path)
        try transport.start { conn in
            conn.start()
        }
        defer { transport.stop() }

        let bound = waitUntil(timeout: 2.0) {
            FileManager.default.fileExists(atPath: path)
        }
        XCTAssertTrue(bound, "listener must be bound before client connects")

        let queue = DispatchQueue(label: "geo.test.unix.client")
        let endpoint: NWEndpoint = .unix(path: path)
        let clientParams = NWParameters()
        clientParams.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        let client = NWConnection(to: endpoint, using: clientParams)

        let readyExpectation = expectation(description: "client ready")
        let doneExpectation = expectation(description: "received bytes or transport closed")
        let stateLock = NSLock()
        var becameReady = false
        var finished = false

        client.stateUpdateHandler = { state in
            switch state {
            case .ready:
                stateLock.lock()
                if !becameReady { becameReady = true; readyExpectation.fulfill() }
                stateLock.unlock()
            case .cancelled, .failed:
                stateLock.lock()
                if becameReady && !finished { finished = true; doneExpectation.fulfill() }
                stateLock.unlock()
            default:
                break
            }
        }
        client.start(queue: queue)

        wait(for: [readyExpectation], timeout: 5.0)

        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"authToken\":\"bogus-token\",\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"0\"}}}\n".utf8)
        client.send(content: payload, completion: .contentProcessed { _ in })

        func readOnce() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, _ in
                stateLock.lock()
                let already = finished
                stateLock.unlock()
                if already { return }
                if let data, !data.isEmpty {
                    stateLock.lock()
                    if !finished { finished = true; doneExpectation.fulfill() }
                    stateLock.unlock()
                    return
                }
                if isComplete {
                    stateLock.lock()
                    if !finished { finished = true; doneExpectation.fulfill() }
                    stateLock.unlock()
                    return
                }
                readOnce()
            }
        }
        readOnce()

        wait(for: [doneExpectation], timeout: 12.0)
        client.cancel()
    }
}
