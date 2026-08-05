import SwiftUI

enum StatusLevel: Equatable {
    case working
    case healthy
    case idle
    case dormant
    case failed

    static func agent(status: String) -> StatusLevel {
        switch status.lowercased() {
        case "working", "running": return .working
        case "idle": return .idle
        default: return .dormant
        }
    }

    static func live(_ active: Bool) -> StatusLevel {
        active ? .healthy : .dormant
    }

    static func link(_ reachable: Bool) -> StatusLevel {
        reachable ? .healthy : .failed
    }

    var tint: Color {
        switch self {
        case .working: return .blue
        case .healthy: return .green
        case .idle, .dormant: return .secondary
        case .failed: return .red
        }
    }

    var isFilled: Bool {
        switch self {
        case .working, .healthy, .idle: return true
        case .dormant, .failed: return false
        }
    }

    var label: String {
        switch self {
        case .working: return "trabalhando"
        case .healthy: return "ativo"
        case .idle: return "parado"
        case .dormant: return "inativo"
        case .failed: return "falha"
        }
    }
}

struct StatusDot: View {
    let level: StatusLevel
    var size: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        mark
            .frame(width: size, height: size)
            .accessibilityLabel(level.label)
            .onAppear { syncPulse() }
            .onChange(of: level) { _, _ in syncPulse() }
            .onChange(of: reduceMotion) { _, _ in syncPulse() }
    }

    @ViewBuilder
    private var mark: some View {
        switch level {
        case .working:
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(level.tint)
                .opacity(pulsing ? 0.4 : 1)
        case .healthy:
            Circle().fill(level.tint)
        case .idle:
            Circle().fill(level.tint).opacity(0.75)
        case .dormant:
            Circle().stroke(level.tint, lineWidth: 1)
        case .failed:
            Circle().stroke(level.tint, lineWidth: max(1.5, size * 0.34))
        }
    }

    private func syncPulse() {
        guard level == .working, !reduceMotion else {
            withAnimation(.spring(response: 0.34, dampingFraction: 1)) { pulsing = false }
            return
        }
        pulsing = false
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
    }
}

extension ServiceCheck {
    var level: StatusLevel {
        switch outcome {
        case .ok: return .healthy
        case .failed: return .failed
        case .running: return .working
        case .pending, .unavailable: return .dormant
        }
    }
}

enum AgentMark {
    static func symbol(for agent: String) -> String? {
        switch agent.lowercased() {
        case "claude": return "asterisk"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "opencode": return "curlybraces"
        case "kimi": return "moon"
        default: return nil
        }
    }

    static func glyph(for agent: String) -> String {
        if agent.lowercased() == "pi" { return "π" }
        guard let first = agent.first else { return "?" }
        return String(first).uppercased()
    }
}

struct AgentBadge: View {
    let agent: String

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        Group {
            if let symbol = AgentMark.symbol(for: agent) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            } else {
                Text(AgentMark.glyph(for: agent))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        }
        .foregroundStyle(.primary)
        .frame(width: 21, height: 21)
        .background(Color.slateInk(0.08), in: shape)
        .overlay(shape.stroke(Color.slateStroke.opacity(0.5), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
