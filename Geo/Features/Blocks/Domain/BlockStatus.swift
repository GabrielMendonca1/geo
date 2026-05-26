import Foundation

enum BlockStatus: String, Codable, CaseIterable, Sendable {
    case active
    case evergreen
    case archived
    case draft
}

extension BlockStatus {
    var displayName: String {
        switch self {
        case .active: return "Active"
        case .evergreen: return "Evergreen"
        case .archived: return "Archived"
        case .draft: return "Draft"
        }
    }

    var icon: String {
        switch self {
        case .active: return "circle.dashed"
        case .evergreen: return "leaf.fill"
        case .archived: return "archivebox"
        case .draft: return "pencil.line"
        }
    }
}
