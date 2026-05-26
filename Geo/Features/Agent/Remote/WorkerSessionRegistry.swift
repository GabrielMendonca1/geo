import Foundation
import Combine

@MainActor
final class WorkerSessionRegistry: ObservableObject {
    struct Session: Identifiable {
        let id: UUID
        let endpointId: UUID
        let endpointName: String
        let connectionId: UUID
        let connection: MCPConnection
        let connectedAt: Date
    }

    @Published private(set) var sessions: [Session] = []

    func register(connection: MCPConnection, endpoint: MCPAuthGuard.ValidatedEndpoint) {
        sessions.removeAll { $0.connectionId == connection.id }
        let session = Session(
            id: UUID(),
            endpointId: endpoint.endpointId,
            endpointName: endpoint.endpointName,
            connectionId: connection.id,
            connection: connection,
            connectedAt: Date()
        )
        sessions.append(session)
    }

    func remove(connectionId: UUID) {
        sessions.removeAll { $0.connectionId == connectionId }
    }

    func session(named name: String) -> Session? {
        sessions.first { $0.endpointName.caseInsensitiveCompare(name) == .orderedSame }
    }

    func session(forEndpointId id: UUID) -> Session? {
        sessions.first { $0.endpointId == id }
    }

    func isOnline(named name: String) -> Bool {
        session(named: name) != nil
    }
}
