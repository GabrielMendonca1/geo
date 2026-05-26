import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "MCPServer")

final class MCPServer: ObservableObject, @unchecked Sendable {
    let router: MCPRouter
    let authGuard: MCPAuthGuard
    let defaultSocketPath: String
    @Published var listenerError: String? = nil
    private var transports: [any MCPTransport] = []
    private var connections: [MCPConnection] = []
    private let queue = DispatchQueue(label: "geo.mcp.server", qos: .userInitiated)
    private var started: Bool = false

    var isRunning: Bool { started }

    var onAuthenticatedConnection: (@Sendable (MCPConnection, MCPAuthGuard.ValidatedEndpoint) -> Void)?
    var onDisconnectedConnection: (@Sendable (UUID) -> Void)?
    var onWorkerNotification: (@Sendable (String, [String: AnyCodableValue]?, MCPAuthGuard.ValidatedEndpoint?) -> Void)?

    var subscriptionManager: SubscriptionManager? {
        get { router.subscriptionManager }
        set { router.subscriptionManager = newValue }
    }

    init(registry: MCPToolRegistry, authGuard: MCPAuthGuard = MCPAuthGuard()) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.defaultSocketPath = appSupport.appendingPathComponent("Geo/mcp.sock").path
        self.router = MCPRouter(registry: registry)
        self.authGuard = authGuard
        self.transports = [UnixSocketTransport(socketPath: defaultSocketPath, router: router, authGuard: authGuard)]
    }

    func enableTCPListener(port: UInt16, bindToAllInterfaces: Bool = false) throws {
        guard !transports.contains(where: { $0 is TCPTransport }) else { return }
        let tcp = TCPTransport(port: port, bindToAllInterfaces: bindToAllInterfaces, router: router, authGuard: authGuard)
        transports.append(tcp)
        do {
            try tcp.start { [weak self] conn in
                self?.register(conn)
                conn.start()
            }
        } catch {
            publishListenerError("TCP listener failed: \(error.localizedDescription)")
            logger.error("TCP listener start failed: \(error.localizedDescription)")
            transports.removeAll { $0 is TCPTransport }
            throw error
        }
    }

    func disableTCPListener() {
        guard let idx = transports.firstIndex(where: { $0 is TCPTransport }) else { return }
        let tcp = transports.remove(at: idx)
        tcp.stop()
    }

    func start() throws {
        publishListenerError(nil)
        for transport in transports {
            do {
                try transport.start { [weak self] conn in
                    self?.register(conn)
                    conn.start()
                }
            } catch {
                let message = "Transport \(transport.identifier) failed to start: \(error.localizedDescription)"
                publishListenerError(message)
                logger.error("\(message)")
                throw error
            }
        }
        if let manager = router.subscriptionManager {
            Task { await manager.start() }
        }
        started = true
    }

    private func publishListenerError(_ message: String?) {
        if Thread.isMainThread {
            self.listenerError = message
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.listenerError = message
            }
        }
    }

    func stop() {
        for transport in transports {
            transport.stop()
        }
        started = false
        if let manager = router.subscriptionManager {
            Task { await manager.stop() }
        }
        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.connections {
                conn.connection.cancel()
            }
            self.connections.removeAll()
        }
        logger.info("MCP server stopped")
    }

    private func register(_ conn: MCPConnection) {
        conn.onDisconnect = { [weak self] id in
            self?.queue.async {
                self?.connections.removeAll { $0.id == id }
            }
            if let manager = self?.router.subscriptionManager {
                Task { await manager.handleDisconnect(connectionId: id) }
            }
            self?.onDisconnectedConnection?(id)
        }
        conn.onAuthenticated = { [weak self] connection, endpoint in
            self?.onAuthenticatedConnection?(connection, endpoint)
        }
        conn.onIncomingNotification = { [weak self] method, params, endpoint in
            self?.onWorkerNotification?(method, params, endpoint)
        }
        queue.async { [weak self] in
            self?.connections.append(conn)
        }
    }
}
