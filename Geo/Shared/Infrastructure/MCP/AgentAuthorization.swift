import Foundation
import os.log

enum AgentOperation {
    case create
    case update
    case delete
    case setLayer
    case setType
    case setStatus
    case setTag
    case linkToDay
    case findBacklinks
    case read
}

enum AuthorizationDecision {
    case allow
    case deny(reason: String)
}

enum AgentAuthorization {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "AgentAuth")

    static func authorize(_ operation: AgentOperation, on blockId: String?, layer: BlockLayer?) -> AuthorizationDecision {
        let allowed: Bool = {
            switch operation {
            case .read:
                return true
            case .create:
                guard let layer = layer else { return true }
                return layer != .user
            case .setLayer:
                guard let layer = layer else { return false }
                return layer != .user
            case .update, .delete, .setType, .setStatus, .setTag, .linkToDay, .findBacklinks:
                guard let layer = layer else { return false }
                return layer.allowsAgentWrites
            }
        }()
        let layerDescription = layer.map { String(describing: $0) } ?? "nil"
        let decision: AuthorizationDecision = allowed
            ? .allow
            : .deny(reason: "operation=\(operation) not permitted on layer=\(layerDescription)")
        logger.info("authz op=\(String(describing: operation)) blockId=\(blockId ?? "nil", privacy: .private) layer=\(layerDescription) decision=\(allowed ? "allow" : "deny")")
        return decision
    }
}
