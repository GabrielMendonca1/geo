import SwiftUI
import AppKit
import Foundation

enum HealthVerdict {
    case healthy, degraded, down

    var label: String {
        switch self {
        case .healthy: return "Healthy"
        case .degraded: return "Degraded"
        case .down: return "Down"
        }
    }

    var dot: DashDot {
        switch self {
        case .healthy: return .green
        case .degraded: return .yellow
        case .down: return .red
        }
    }
}

struct DashHeader: View {
    @ObservedObject var service: HermesStatusService
    let totalToday: Int
    @State private var feedback: String?
    @State private var feedbackIsError = false

    var body: some View {
        HStack(spacing: 14) {
            Text("Hermes")
                .font(GeoStyle.Typography.titleFont(size: 26))
                .foregroundStyle(Palette.foreground)

            StatusChip(verdict: verdict)

            Text("\(totalToday) handled")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.tertiaryForeground)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.5), value: totalToday)

            if let tick = service.lastTick {
                Text("· tick \(relativeTime(tick))")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiaryForeground.opacity(0.8))
            }

            if let feedback {
                Text(feedback)
                    .font(.system(size: 12))
                    .foregroundStyle(feedbackIsError ? Color(nsColor: Palette.agentDanger) : Palette.tertiaryForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }

            Spacer(minLength: 12)

            OpsPill(label: "Restart", icon: "arrow.clockwise", action: restartHermes)
            OpsPill(label: "SOUL", icon: "doc.text", action: openSoul)
            OpsPill(label: "Log", icon: "list.bullet.rectangle", action: tailLog)
            OpsPill(label: "Files", icon: "folder", action: revealHermes)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var verdict: HealthVerdict {
        guard service.setupState == .running, service.mcpConnected else { return .down }
        let bad = service.connectors.contains { c in
            switch c.status {
            case .error, .disconnected: return true
            case .connected, .connecting: return false
            }
        }
        return bad ? .degraded : .healthy
    }

    private func openSoul() {
        let path = NSString(string: "~/.hermes/SOUL.md").expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func tailLog() {
        let logURL = URL(fileURLWithPath: NSString(string: "~/.hermes/logs/gateway.log").expandingTildeInPath)
        let consoleURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([logURL], withApplicationAt: consoleURL, configuration: config) { _, error in
            if let error {
                show("console: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func restartHermes() {
        show("restarting…", isError: false)
        Task.detached {
            let uid = getuid()
            let target = "gui/\(uid)/ai.hermes.gateway"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", target]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    await MainActor.run { show("restarted hermes", isError: false) }
                } else {
                    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                    let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        if let msg, !msg.isEmpty {
                            show(msg, isError: true)
                        } else {
                            show("exit \(process.terminationStatus)", isError: true)
                        }
                    }
                }
            } catch {
                await MainActor.run { show(error.localizedDescription, isError: true) }
            }
        }
    }

    private func revealHermes() {
        let path = NSString(string: "~/.hermes").expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func show(_ text: String, isError: Bool) {
        feedback = text
        feedbackIsError = isError
        let snapshot = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if feedback == snapshot { feedback = nil }
        }
    }
}

struct StatusChip: View {
    let verdict: HealthVerdict

    var body: some View {
        HStack(spacing: 7) {
            PulsingDot(dot: verdict.dot).frame(width: 12, height: 12)
            Text(verdict.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(verdict.dot.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(verdict.dot.color.opacity(0.12)))
    }
}

struct OpsPill: View {
    let label: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(label).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(Palette.foreground)
            .background(Capsule().fill(hovering ? Palette.foreground.opacity(0.06) : Color.clear))
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering = $0 }
    }
}

struct GeoCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                Text(title)
                    .font(GeoStyle.Typography.titleFont(size: 17))
                    .foregroundStyle(Palette.foreground)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.background))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
    }
}

struct HermesSetupBanner: View {
    @ObservedObject var service: HermesStatusService

    var body: some View {
        let copy = bannerCopy
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: copy.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(GeoColors.blue)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                Text(copy.body)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = copy.hint {
                    Text(hint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.tertiaryForeground.opacity(0.85))
                        .padding(.top, 1)
                }
                if let error = service.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Palette.agentDanger))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Button {
                copy.action()
            } label: {
                HStack(spacing: 5) {
                    if service.setupActionInFlight {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: copy.buttonIcon).font(.system(size: 11, weight: .medium))
                    }
                    Text(copy.buttonLabel).font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(GeoColors.blue))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(service.setupActionInFlight)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(GeoColors.blue.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(GeoColors.blue.opacity(0.30), lineWidth: 1))
    }

    private struct BannerCopy {
        let icon: String
        let title: String
        let body: String
        let hint: String?
        let buttonLabel: String
        let buttonIcon: String
        let action: () -> Void
    }

    private var bannerCopy: BannerCopy {
        switch service.setupState {
        case .notInstalled:
            return BannerCopy(
                icon: "shippingbox.fill",
                title: "Hermes is not installed",
                body: "Hermes is the always-on agent that powers Geo's Telegram, WhatsApp, and Gmail integration. Install it to enable channels and the kanban dispatch.",
                hint: "After install, run ./hermes/install.sh from this repo to seed config + ~/.hermes/.env.",
                buttonLabel: "Install Hermes",
                buttonIcon: "arrow.down.circle.fill",
                action: { [service] in service.installHermes() }
            )
        case .installedNotRunning:
            return BannerCopy(
                icon: "power.circle.fill",
                title: "Hermes is installed but not running",
                body: "The hermes binary is on PATH but the LaunchAgent is stopped. Start the gateway to enable channels.",
                hint: nil,
                buttonLabel: "Start Hermes",
                buttonIcon: "play.fill",
                action: { [service] in service.startGateway() }
            )
        case .running:
            return BannerCopy(
                icon: "checkmark.circle.fill",
                title: "Hermes is running",
                body: "",
                hint: nil,
                buttonLabel: "OK",
                buttonIcon: "checkmark",
                action: {}
            )
        }
    }
}
