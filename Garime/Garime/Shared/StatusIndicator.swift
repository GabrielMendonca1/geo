import SwiftUI
import UIKit

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

private enum AgentPalette {
    static let claude = rgb(0xD9, 0x77, 0x57)
    static let codex = rgb(0x10, 0xA3, 0x7F)
    static let opencode = rgb(0x4A, 0x6C, 0x8A)
    static let kimi = rgb(0x6C, 0x5C, 0xE7)
    static let neutral = rgb(0x8E, 0x8E, 0x93)
    static let pi = UIColor { $0.userInterfaceStyle == .dark ? rgb(0x24, 0x24, 0x28) : rgb(0x0B, 0x0B, 0x0D) }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

enum HostMark {
    static func symbol(for host: String) -> String {
        host.lowercased() == "mac" ? "laptopcomputer" : "server.rack"
    }

    static func label(for host: String) -> String {
        host.lowercased() == "mac" ? "mac" : "vm"
    }
}

struct HostBadge: View {
    let host: String

    var body: some View {
        Image(systemName: HostMark.symbol(for: host))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.slateTextDim)
            .frame(width: 20, height: 16)
            .accessibilityLabel(HostMark.label(for: host))
    }
}

enum AgentMark {
    static func tint(for agent: String) -> Color {
        switch agent.lowercased() {
        case "claude": return Color(AgentPalette.claude)
        case "codex": return Color(AgentPalette.codex)
        case "opencode": return Color(AgentPalette.opencode)
        case "kimi": return Color(AgentPalette.kimi)
        case "pi": return Color(AgentPalette.pi)
        default: return Color(AgentPalette.neutral)
        }
    }

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
        .foregroundStyle(.white)
        .frame(width: 21, height: 21)
        .background(AgentMark.tint(for: agent), in: shape)
        .overlay(shape.stroke(Color.slateStroke.opacity(0.5), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
