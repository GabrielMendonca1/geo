import Foundation
import Network
import os.log

private let unixLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "UnixSocketTransport")

final class UnixSocketTransport: MCPTransport, @unchecked Sendable {
    let identifier: String
    let requiresAuth: Bool = true

    private let socketPath: String
    private let router: MCPRouter
    private let authGuard: MCPAuthGuard
    private let queue = DispatchQueue(label: "geo.mcp.transport.unix", qos: .userInitiated)
    private var listener: NWListener?

    init(socketPath: String, router: MCPRouter, authGuard: MCPAuthGuard) {
        self.socketPath = socketPath
        self.router = router
        self.authGuard = authGuard
        self.identifier = "unix:\(socketPath)"
    }

    func start(onConnection: @Sendable @escaping (MCPConnection) -> Void) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            try fm.removeItem(atPath: socketPath)
        }
        let parentDir = (socketPath as NSString).deletingLastPathComponent
        if !parentDir.isEmpty && !fm.fileExists(atPath: parentDir) {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        let listener = try NWListener(using: params)

        listener.stateUpdateHandler = { [socketPath] state in
            switch state {
            case .ready:
                unixLogger.info("MCP Unix listener ready on \(socketPath)")
                do {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socketPath)
                } catch {
                    unixLogger.error("Failed to chmod mcp.sock: \(error.localizedDescription)")
                }
            case .failed(let error):
                unixLogger.error("MCP Unix listener failed: \(error.localizedDescription)")
            case .cancelled:
                unixLogger.info("MCP Unix listener cancelled")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [router] nwConnection in
            let conn = MCPConnection(connection: nwConnection, router: router, authGuard: nil)
            onConnection(conn)
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}
