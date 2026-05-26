import SwiftUI

enum AIAgentKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case pi

    var id: String { rawValue }

    var label: String { "pi" }

    var displayName: String { label }

    var shortLabel: String { "pi" }

    var executableName: String { "pi" }

    var symbolName: String { "sparkles" }

    var tint: Color { Color(red: 0.40, green: 0.50, blue: 0.95) }
}

enum AIServiceStatus: String, Codable, Hashable {
    case stopped
    case running
    case degraded

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .running: return "Running"
        case .degraded: return "Needs config"
        }
    }

    var symbolName: String {
        switch self {
        case .stopped: return "pause.circle"
        case .running: return "play.circle.fill"
        case .degraded: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .stopped: return .secondary
        case .running: return .green
        case .degraded: return .orange
        }
    }
}

enum AIRunStatus: String, Codable, Hashable {
    case preparing
    case launching
    case running
    case succeeded
    case failed
    case timedOut
    case stalled
    case canceled
    case retryQueued

    var label: String {
        switch self {
        case .preparing: return "Preparing"
        case .launching: return "Launching"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .timedOut: return "Timed out"
        case .stalled: return "Stalled"
        case .canceled: return "Canceled"
        case .retryQueued: return "Retry queued"
        }
    }

    var symbolName: String {
        switch self {
        case .preparing: return "folder.badge.gearshape"
        case .launching: return "arrow.up.forward.app"
        case .running: return "bolt.fill"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .timedOut: return "timer"
        case .stalled: return "hourglass"
        case .canceled: return "minus.circle"
        case .retryQueued: return "arrow.clockwise.circle"
        }
    }

    var tint: Color {
        switch self {
        case .preparing, .launching, .retryQueued: return .orange
        case .running: return .blue
        case .succeeded: return .green
        case .failed, .timedOut, .stalled: return .red
        case .canceled: return .secondary
        }
    }
}

enum AILogLevel: String, Codable, Hashable {
    case info
    case warning
    case error

    var symbolName: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
