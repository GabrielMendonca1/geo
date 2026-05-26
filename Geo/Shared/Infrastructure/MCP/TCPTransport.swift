import Foundation
import Network
import os.log

private let tcpLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "TCPTransport")

final class TCPTransport: MCPTransport, @unchecked Sendable {
    let identifier: String
    let requiresAuth: Bool = true

    private let port: UInt16
    private let bindToAllInterfaces: Bool
    private let router: MCPRouter
    private let authGuard: MCPAuthGuard
    private let queue = DispatchQueue(label: "geo.mcp.transport.tcp", qos: .userInitiated)
    private var listener: NWListener?

    init(port: UInt16, bindToAllInterfaces: Bool = false, router: MCPRouter, authGuard: MCPAuthGuard) {
        self.port = port
        self.bindToAllInterfaces = bindToAllInterfaces
        self.router = router
        self.authGuard = authGuard
        self.identifier = "tcp:\(bindToAllInterfaces ? "0.0.0.0" : "127.0.0.1"):\(port)"
    }

    func start(onConnection: @Sendable @escaping (MCPConnection) -> Void) throws {
        if bindToAllInterfaces {
            throw TCPTransportError.insecureBindRefused
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TCPTransportError.invalidPort(port)
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 60

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.acceptLocalOnly = !bindToAllInterfaces

        let listener = try NWListener(using: params, on: nwPort)

        listener.stateUpdateHandler = { [identifier = self.identifier] state in
            switch state {
            case .ready:
                tcpLogger.info("MCP TCP listener ready — \(identifier)")
            case .failed(let error):
                tcpLogger.error("MCP TCP listener failed: \(error.localizedDescription)")
            case .cancelled:
                tcpLogger.info("MCP TCP listener cancelled — \(identifier)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [router, authGuard] nwConnection in
            let conn = MCPConnection(connection: nwConnection, router: router, authGuard: authGuard)
            onConnection(conn)
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

enum TCPTransportError: Error, LocalizedError {
    case invalidPort(UInt16)
    case insecureBindRefused

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid TCP port: \(port)"
        case .insecureBindRefused:
            return "TCP MCP without TLS may only bind to loopback."
        }
    }
}
