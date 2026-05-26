import Foundation

protocol MCPTransport: AnyObject, Sendable {
    var identifier: String { get }
    var requiresAuth: Bool { get }

    func start(onConnection: @Sendable @escaping (MCPConnection) -> Void) throws
    func stop()
}
