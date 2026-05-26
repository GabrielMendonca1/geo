import Foundation

enum BlockType: String, Codable, CaseIterable, Sendable {
    case fleeting
    case literature
    case permanent
    case moc
    case project
}

enum BlockLayer: String, Codable, CaseIterable, Sendable {
    case user
    case agent
    case review
    case shared
}

extension BlockType {
    static let `default`: BlockType = .fleeting

    var displayName: String {
        switch self {
        case .permanent: return "Permanent"
        case .project: return "Projeto"
        case .moc: return "MOC"
        case .fleeting: return "Fleeting"
        case .literature: return "Literature"
        }
    }

    var icon: String {
        switch self {
        case .permanent: return "book.closed.fill"
        case .project: return "hammer.fill"
        case .moc: return "point.3.connected.trianglepath.dotted"
        case .fleeting: return "bolt.fill"
        case .literature: return "quote.bubble.fill"
        }
    }
}

extension BlockLayer {
    static let `default`: BlockLayer = .user

    var displayName: String {
        switch self {
        case .user: return "Você"
        case .agent: return "Agente"
        case .review: return "Revisão"
        case .shared: return "Compartilhado"
        }
    }

    var icon: String {
        switch self {
        case .user: return "person.fill"
        case .agent: return "sparkles"
        case .review: return "checklist"
        case .shared: return "arrow.triangle.2.circlepath"
        }
    }

    var allowsAgentWrites: Bool {
        switch self {
        case .user:
            return false
        case .agent, .review, .shared:
            return true
        }
    }
}
