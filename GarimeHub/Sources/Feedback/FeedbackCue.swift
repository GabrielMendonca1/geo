import Foundation

enum FeedbackPriority {
    case ambient
    case lifecycle
    case alert
}

enum FeedbackCue: String, CaseIterable {
    case sectorChanged
    case selection
    case start
    case completed
    case cancelled
    case error

    var priority: FeedbackPriority {
        switch self {
        case .sectorChanged:
            return .ambient
        case .selection, .start, .completed, .cancelled:
            return .lifecycle
        case .error:
            return .alert
        }
    }

    var coalesceWindow: TimeInterval {
        switch self {
        case .sectorChanged:
            return 0.11
        case .selection:
            return 0.09
        case .start, .completed, .cancelled:
            return 0.30
        case .error:
            return 0.45
        }
    }

    var relativeGain: Double {
        switch self {
        case .sectorChanged:
            return 0.55
        case .selection:
            return 0.7
        case .start:
            return 0.85
        case .completed:
            return 0.9
        case .cancelled:
            return 0.8
        case .error:
            return 1.0
        }
    }
}

enum FeedbackTiming {
    static let globalMinimumGap: TimeInterval = 0.045
    static let idleTeardownDelay: TimeInterval = 4.0
}
