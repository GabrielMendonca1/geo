import SwiftUI
import Foundation

enum DashDot { case green, yellow, red, gray
    var color: Color {
        switch self {
        case .green: return Color(nsColor: Palette.agentSuccess)
        case .yellow: return Color(nsColor: Palette.agentWarning)
        case .red: return Color(nsColor: Palette.agentDanger)
        case .gray: return Palette.tertiaryForeground
        }
    }
    var pulses: Bool { self == .green }
}

struct PulsingDot: View {
    let dot: DashDot
    @Environment(\.tabRouter) private var tabRouter
    @State private var animate = false

    private var isActive: Bool { dot.pulses && tabRouter.selectedTab == .nano }

    var body: some View {
        ZStack {
            if isActive {
                Circle()
                    .fill(dot.color.opacity(0.5))
                    .frame(width: 12, height: 12)
                    .scaleEffect(animate ? 1.4 : 0.8)
                    .opacity(animate ? 0 : 0.6)
            }
            Circle().fill(dot.color).frame(width: 7, height: 7)
        }
        .onAppear { restartPulse() }
        .onChange(of: isActive) { _, _ in restartPulse() }
    }

    private func restartPulse() {
        guard isActive else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { animate = false }
            return
        }
        animate = false
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            animate = true
        }
    }
}

enum ChannelStyle {
    static func label(_ kind: String) -> String {
        switch kind {
        case "telegram": return "Telegram"
        case "whatsapp": return "WhatsApp"
        case "gmail": return "Gmail"
        case "nano": return "Nano"
        case "cron": return "Scheduled"
        case "cli": return "CLI"
        default: return kind.capitalized
        }
    }

    static func tint(_ kind: String) -> Color {
        switch kind {
        case "telegram": return Color(red: 0.15, green: 0.59, blue: 0.91)
        case "whatsapp": return Color(red: 0.07, green: 0.71, blue: 0.42)
        case "gmail": return Color(red: 0.96, green: 0.55, blue: 0.13)
        case "nano": return Color(red: 0.55, green: 0.40, blue: 0.93)
        default: return GeoColors.blue
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "telegram": return "paperplane.fill"
        case "whatsapp": return "bubble.left.fill"
        case "gmail": return "envelope.fill"
        case "nano": return "rectangle.grid.2x2.fill"
        default: return "circle.fill"
        }
    }
}

enum GeoColors {
    static let blue = Color(red: 0.0, green: 0.33, blue: 1.0)
    static let blueLight = Color(red: 0.4, green: 0.6, blue: 1.0)
}

func relativeTime(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
}
