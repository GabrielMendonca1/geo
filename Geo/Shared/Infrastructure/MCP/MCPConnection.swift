import Foundation
import Network
import os
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "MCPConnection")

enum MCPConnectionError: Error {
    case timeout
    case sendFailed(Error)
    case notConnected
    case encodeFailed(Error)
}

private struct MCPConnectionState: @unchecked Sendable {
    var pending: [String: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    var nextOutboundId: Int = 100_000
}

final class MCPConnection: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    private let router: MCPRouter
    private let authGuard: MCPAuthGuard?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let framer = MCPFramer()
    private var authenticated: Bool
    private var boundEndpoint: MCPAuthGuard.ValidatedEndpoint?

    private let state = OSAllocatedUnfairLock(initialState: MCPConnectionState())

    var onDisconnect: ((UUID) -> Void)?
    var onAuthenticated: (@Sendable (MCPConnection, MCPAuthGuard.ValidatedEndpoint) -> Void)?
    var onIncomingNotification: (@Sendable (String, [String: AnyCodableValue]?, MCPAuthGuard.ValidatedEndpoint?) -> Void)?

    init(connection: NWConnection, router: MCPRouter, authGuard: MCPAuthGuard? = nil) {
        self.connection = connection
        self.router = router
        self.authGuard = authGuard
        self.authenticated = (authGuard == nil)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                logger.info("MCP connection ready")
                self.readLoop()
            case .failed(let error):
                logger.error("MCP connection failed: \(error.localizedDescription)")
                self.failPending(MCPConnectionError.sendFailed(error))
                self.onDisconnect?(self.id)
                self.connection.cancel()
            case .cancelled:
                logger.info("MCP connection cancelled")
                self.failPending(MCPConnectionError.notConnected)
                self.onDisconnect?(self.id)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    func sendRequest(
        method: String,
        params: [String: AnyCodableValue]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> JSONRPCResponse {
        let outboundId = nextOutboundIdAndIncrement()
        let id = JSONRPCID.int(outboundId)
        let request = JSONRPCRequest(jsonrpc: "2.0", id: id, method: method, params: params)
        let key = Self.idKey(id)

        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                state.pending[key] = continuation
            }

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                let cont = self.state.withLock { state in
                    state.pending.removeValue(forKey: key)
                }
                cont?.resume(throwing: MCPConnectionError.timeout)
            }

            do {
                let payload = try encoder.encode(request)
                let framed = MCPFramer.encodeFrame(payload)
                connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        let cont = self.state.withLock { state in
                            state.pending.removeValue(forKey: key)
                        }
                        cont?.resume(throwing: MCPConnectionError.sendFailed(error))
                    }
                })
            } catch {
                let cont = state.withLock { state in
                    state.pending.removeValue(forKey: key)
                }
                cont?.resume(throwing: MCPConnectionError.encodeFailed(error))
            }
        }
    }

    func sendNotification(method: String, params: [String: AnyCodableValue]? = nil) {
        let request = JSONRPCRequest(jsonrpc: "2.0", id: nil, method: method, params: params)
        do {
            let payload = try encoder.encode(request)
            let framed = MCPFramer.encodeFrame(payload)
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    logger.error("Notification send failed: \(error.localizedDescription)")
                }
            })
        } catch {
            logger.error("Notification encode failed: \(error.localizedDescription)")
        }
    }

    private func readLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                logger.error("Read error: \(error.localizedDescription)")
                self.connection.cancel()
                return
            }

            if let data = content {
                switch self.framer.feed(data) {
                case .frames(let frames):
                    for frame in frames {
                        self.processLine(frame)
                    }
                case .overflow:
                    logger.error("MCP framer buffer overflow; closing connection")
                    self.connection.cancel()
                    return
                }
            }

            if isComplete {
                self.connection.cancel()
            } else {
                self.readLoop()
            }
        }
    }

    private func processLine(_ data: Data) {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to parse JSON")
            sendResponse(JSONRPCResponse.error(id: nil, code: JSONRPCError.parseError, message: "Parse error"))
            return
        }

        if raw["method"] != nil {
            do {
                let request = try decoder.decode(JSONRPCRequest.self, from: data)
                handleIncomingRequest(request)
            } catch {
                logger.error("Failed to decode request: \(error.localizedDescription)")
                sendResponse(JSONRPCResponse.error(id: nil, code: JSONRPCError.parseError, message: "Parse error"))
            }
            return
        }

        if raw["result"] != nil || raw["error"] != nil {
            if let response = try? decoder.decode(JSONRPCResponse.self, from: data) {
                handleIncomingResponse(response)
            }
            return
        }

        logger.warning("Unknown JSON-RPC payload shape — ignoring")
    }

    private func handleIncomingRequest(_ request: JSONRPCRequest) {
        if !authenticated {
            handleAuthHandshake(request: request)
            return
        }

        if request.id == nil {
            onIncomingNotification?(request.method, request.params, boundEndpoint)
            Task { [weak self] in
                guard let self else { return }
                _ = await self.router.handle(request, connection: self)
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let response = await self.router.handle(request, connection: self)
            self.sendResponse(response)
        }
    }

    private func handleIncomingResponse(_ response: JSONRPCResponse) {
        guard let id = response.id else { return }
        let key = Self.idKey(id)
        let cont = state.withLock { state in
            state.pending.removeValue(forKey: key)
        }
        cont?.resume(returning: response)
    }

    private func handleAuthHandshake(request: JSONRPCRequest) {
        guard let authGuard else {
            authenticated = true
            return
        }

        guard request.method == "initialize" else {
            sendResponse(.error(id: request.id, code: JSONRPCError.invalidRequest, message: "First message must be 'initialize' with authToken"), thenCancel: true)
            return
        }

        guard let token = extractToken(from: request.params),
              let validated = authGuard.validate(token: token, clientId: peerClientId())
        else {
            logger.warning("MCP connection rejected — invalid or missing auth token")
            sendResponse(.error(id: request.id, code: JSONRPCError.invalidRequest, message: "Unauthorized"), thenCancel: true)
            return
        }

        authenticated = true
        boundEndpoint = validated
        logger.info("MCP connection authenticated — endpoint '\(validated.endpointName)'")
        onAuthenticated?(self, validated)

        Task { [weak self] in
            guard let self else { return }
            let response = await self.router.handle(request, connection: self)
            self.sendResponse(response)
        }
    }

    private func peerClientId() -> String {
        switch connection.endpoint {
        case .hostPort(let host, let port):
            let hostString: String
            switch host {
            case .name(let name, _): hostString = name
            case .ipv4(let addr): hostString = "\(addr)"
            case .ipv6(let addr): hostString = "\(addr)"
            @unknown default: hostString = "unknown"
            }
            return "\(hostString):\(port.rawValue)"
        case .unix:
            return "unix-local"
        case .url(let url):
            return url.absoluteString
        case .service(let name, _, _, _):
            return "service:\(name)"
        case .opaque:
            return "opaque"
        @unknown default:
            return "unknown"
        }
    }

    private func extractToken(from params: [String: AnyCodableValue]?) -> String? {
        guard let params else { return nil }
        if case .string(let token)? = params["authToken"] { return token }
        if case .object(let meta)? = params["_meta"], case .string(let token)? = meta["authToken"] { return token }
        if case .object(let auth)? = params["auth"], case .string(let token)? = auth["token"] { return token }
        return nil
    }

    private func sendResponse(_ response: JSONRPCResponse, thenCancel: Bool = false) {
        do {
            let payload = try encoder.encode(response)
            let framed = MCPFramer.encodeFrame(payload)
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                if let error {
                    logger.error("Write error: \(error.localizedDescription)")
                }
                if thenCancel { self?.connection.cancel() }
            })
        } catch {
            logger.error("Failed to encode response: \(error.localizedDescription)")
            if thenCancel { connection.cancel() }
        }
    }

    private func failPending(_ error: Error) {
        let conts = state.withLock { state in
            let conts = Array(state.pending.values)
            state.pending.removeAll()
            return conts
        }
        for cont in conts {
            cont.resume(throwing: error)
        }
    }

    private func nextOutboundIdAndIncrement() -> Int {
        state.withLock { state in
            let id = state.nextOutboundId
            state.nextOutboundId += 1
            return id
        }
    }

    private static func idKey(_ id: JSONRPCID) -> String {
        switch id {
        case .int(let i): return "i:\(i)"
        case .string(let s): return "s:\(s)"
        case .null: return "n"
        }
    }
}
