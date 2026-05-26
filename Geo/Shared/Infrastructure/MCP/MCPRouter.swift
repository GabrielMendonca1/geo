import Foundation
import os
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "MCPRouter")

final class MCPRouter: @unchecked Sendable {
    private let registry: MCPToolRegistry
    private let subscriptionManagerLock = OSAllocatedUnfairLock<SubscriptionManager?>(initialState: nil)

    init(registry: MCPToolRegistry) {
        self.registry = registry
    }

    var subscriptionManager: SubscriptionManager? {
        get { subscriptionManagerLock.withLock { $0 } }
        set { subscriptionManagerLock.withLock { $0 = newValue } }
    }

    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        await handle(request, connection: nil)
    }

    func handle(_ request: JSONRPCRequest, connection: MCPConnection?) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(id: request.id)
        case "notifications/initialized":
            return .success(id: request.id, result: .object([:]))
        case "tools/list":
            return handleToolsList(id: request.id)
        case "tools/call":
            return await handleToolCall(id: request.id, params: request.params)
        case "ping":
            return .success(id: request.id, result: .object([:]))
        case "geo/subscribe":
            return await handleSubscribe(id: request.id, params: request.params, connection: connection)
        case "geo/unsubscribe":
            return await handleUnsubscribe(id: request.id, params: request.params, connection: connection)
        default:
            logger.warning("Unknown method: \(request.method)")
            return .error(id: request.id, code: JSONRPCError.methodNotFound, message: "Method not found: \(request.method)")
        }
    }

    private func handleInitialize(id: JSONRPCID?) -> JSONRPCResponse {
        let result = MCPInitializeResult(
            protocolVersion: "2025-11-25",
            capabilities: MCPCapabilities(tools: .init(listChanged: false)),
            serverInfo: MCPServerInfo(name: "geo", version: "1.0.0")
        )
        guard let encoded = AnyCodableValue.from(result) else {
            return .error(id: id, code: JSONRPCError.internalError, message: "Failed to encode initialize result")
        }
        return .success(id: id, result: encoded)
    }

    private func handleToolsList(id: JSONRPCID?) -> JSONRPCResponse {
        let defs = registry.definitions
        guard let encoded = AnyCodableValue.from(["tools": defs]) else {
            return .error(id: id, code: JSONRPCError.internalError, message: "Failed to encode tools list")
        }
        return .success(id: id, result: encoded)
    }

    private func handleToolCall(id: JSONRPCID?, params: [String: AnyCodableValue]?) async -> JSONRPCResponse {
        guard let params,
              let name = params["name"]?.stringValue else {
            return .error(id: id, code: JSONRPCError.invalidParams, message: "Missing tool name")
        }

        let arguments: [String: AnyCodableValue]
        if let argsValue = params["arguments"]?.objectValue {
            arguments = argsValue
        } else {
            arguments = [:]
        }

        do {
            let result = try await registry.call(name: name, arguments: arguments)
            guard let encoded = AnyCodableValue.from(result) else {
                return .error(id: id, code: JSONRPCError.internalError, message: "Failed to encode tool result")
            }
            return .success(id: id, result: encoded)
        } catch {
            logger.error("Tool call failed: \(name) — \(error.localizedDescription)")
            let errorResult = MCPToolResult.error("operation failed")
            guard let encoded = AnyCodableValue.from(errorResult) else {
                return .error(id: id, code: JSONRPCError.internalError, message: "internal error")
            }
            return .success(id: id, result: encoded)
        }
    }

    private func handleSubscribe(id: JSONRPCID?, params: [String: AnyCodableValue]?, connection: MCPConnection?) async -> JSONRPCResponse {
        guard let connection else {
            return .error(id: id, code: JSONRPCError.invalidRequest, message: "geo/subscribe requires a connection")
        }
        guard let manager = subscriptionManager else {
            return .error(id: id, code: JSONRPCError.methodNotFound, message: "Subscriptions are not available")
        }
        let kinds = SubscriptionParams.parseKinds(params)
        let connectionId = connection.id
        let weakConn = WeakConnection(connection)
        let notify: SubscriptionManager.Notifier = { params in
            weakConn.value?.sendNotification(method: "geo/changed", params: params)
        }
        let resolved = await manager.subscribe(connectionId: connectionId, kinds: kinds, notify: notify)
        let sortedKinds = resolved.map { $0.rawValue }.sorted()
        let result: AnyCodableValue = .object([
            "ok": .bool(true),
            "subscribed": .array(sortedKinds.map { .string($0) }),
        ])
        return .success(id: id, result: result)
    }

    private func handleUnsubscribe(id: JSONRPCID?, params: [String: AnyCodableValue]?, connection: MCPConnection?) async -> JSONRPCResponse {
        guard let connection else {
            return .error(id: id, code: JSONRPCError.invalidRequest, message: "geo/unsubscribe requires a connection")
        }
        guard let manager = subscriptionManager else {
            return .error(id: id, code: JSONRPCError.methodNotFound, message: "Subscriptions are not available")
        }
        let parsed = SubscriptionParams.parseKinds(params)
        let kinds: Set<SubscriptionKind>? = parsed.isEmpty ? nil : parsed
        await manager.unsubscribe(connectionId: connection.id, kinds: kinds)
        let result: AnyCodableValue = .object(["ok": .bool(true)])
        return .success(id: id, result: result)
    }
}

private final class WeakConnection: @unchecked Sendable {
    weak var value: MCPConnection?
    init(_ value: MCPConnection) {
        self.value = value
    }
}
