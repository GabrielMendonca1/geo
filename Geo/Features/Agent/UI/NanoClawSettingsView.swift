import AppKit
import SwiftUI

struct NanoClawSettingsView: View {
    @EnvironmentObject private var service: NanoClawService
    @EnvironmentObject private var endpointRegistry: EndpointRegistry

    @State private var installRunning: Bool = false
    @State private var installLog: String = ""
    @State private var installError: String?
    @State private var tokenMessage: String?
    @State private var tokenAlert: String?
    @State private var showDisconnectConfirmation: ConnectorDisconnect?

    private static let endpointName = "geo-claw"

    private struct ConnectorDisconnect: Identifiable {
        let id: String
        let title: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            mcpStatusRow
            connectorCard(id: "whatsapp", title: "WhatsApp", icon: "message.fill", fallbackTint: .green, pairLabel: "Pair", showQR: true)
            connectorCard(id: "gmail", title: "Gmail", icon: "envelope.fill", fallbackTint: .orange, pairLabel: "Authorize", showQR: false)
            if !service.launchAgentInstalled {
                daemonInstallCard
            }
            tokenCard
            ClawJobsSection()
                .environmentObject(service)
        }
        .onAppear { service.refreshLaunchAgentInstalled() }
        .confirmationDialog(
            "Disconnect this connector?",
            isPresented: Binding(
                get: { showDisconnectConfirmation != nil },
                set: { if !$0 { showDisconnectConfirmation = nil } }
            ),
            presenting: showDisconnectConfirmation
        ) { item in
            Button("Disconnect \(item.title)", role: .destructive) {
                service.requestDisconnect(item.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("The agent will stop receiving messages from \(item.title) until you reconnect.")
        }
        .alert(
            "Token error",
            isPresented: Binding(
                get: { tokenAlert != nil },
                set: { if !$0 { tokenAlert = nil } }
            ),
            presenting: tokenAlert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Geo Claw — 24/7 assistant")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Connects WhatsApp and Gmail through the geo-claw daemon so the agent can act on your behalf around the clock.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mcpStatusRow: some View {
        let dotColor: Color = service.mcpConnected
            ? Color(red: 0.18, green: 0.78, blue: 0.46)
            : Color(white: 0.42)
        return HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(service.mcpConnected ? "MCP Connected" : "MCP Disconnected")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if let mcpError = service.mcpError, !service.mcpConnected {
                    Text(mcpError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let lastTick = service.lastTick {
                Text("Last tick: \(formatted(lastTick))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Last MCP heartbeat at \(formatted(lastTick))")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func connectorCard(
        id: String,
        title: String,
        icon: String,
        fallbackTint: Color,
        pairLabel: String,
        showQR: Bool
    ) -> some View {
        let connector = service.connectors.first(where: { $0.id == id })
        let isPairing: Bool = {
            guard let s = connector?.status, case .connecting = s else { return false }
            return true
        }()
        let isConnected: Bool = {
            guard let s = connector?.status, case .connected = s else { return false }
            return true
        }()
        return ClawCard(title: title, icon: icon, iconTint: connector?.tint ?? fallbackTint) {
            VStack(alignment: .leading, spacing: 12) {
                StatePill(connector: connector)
                if showQR && isPairing { qrPanel }
                if let identity = connector?.identity, !identity.isEmpty {
                    Text(identity).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button(pairLabel) { service.requestPair(id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isPairing || isConnected)
                        .accessibilityLabel("\(pairLabel) \(title)")
                    Button("Disconnect") {
                        showDisconnectConfirmation = ConnectorDisconnect(id: id, title: title)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isConnected)
                    .accessibilityLabel("Disconnect \(title)")
                }
            }
        }
    }

    private var qrPanel: some View {
        VStack(alignment: .center, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 256, height: 256)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                if let qr = service.whatsappQR {
                    Image(nsImage: qr)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(8)
                        .frame(width: 256, height: 256)
                        .accessibilityLabel("WhatsApp pairing QR code")
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Generating QR…")
                            .font(.caption)
                            .foregroundStyle(.black.opacity(0.55))
                    }
                    .accessibilityLabel("Generating WhatsApp QR code")
                }
            }
            Text("WhatsApp → Settings → Linked Devices → Link a Device")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var daemonInstallCard: some View {
        ClawCard(title: "Install Daemon", icon: "gearshape.2.fill", iconTint: .blue) {
            VStack(alignment: .leading, spacing: 10) {
                Text("geo-claw isn't running yet. Install the LaunchAgent so it starts when you log in.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Button("Install") { runInstaller() }
                        .buttonStyle(.borderedProminent)
                        .disabled(installRunning)
                        .accessibilityLabel("Install geo-claw LaunchAgent")
                    if installRunning { ProgressView().controlSize(.small) }
                }
                if let installError {
                    Label(installError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if service.launchAgentInstalled, !installLog.isEmpty {
                    Label("Installed. Daemon will start automatically on login.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if !installLog.isEmpty {
                    ScrollView {
                        Text(installLog)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    private var tokenCard: some View {
        ClawCard(title: "MCP Token", icon: "key.fill", iconTint: .purple) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Issue or rotate the token that geo-claw uses to talk to Geo's MCP server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Re-issue token") { reissueToken() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Re-issue MCP token")
                if let tokenMessage {
                    Text(tokenMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: date)
    }

    private func runInstaller() {
        installRunning = true
        installError = nil
        installLog = ""
        Task {
            do {
                let result = try await service.installLaunchAgent()
                self.installLog = result.combinedOutput
                self.installRunning = false
                self.bootstrapTokenAfterInstall()
            } catch {
                self.installLog = ""
                self.installRunning = false
                self.installError = error.localizedDescription
            }
        }
    }

    private func issueToken(rotate: Bool, success: String, failurePrefix: String) {
        do {
            try service.bootstrapMcpToken(try ensureEndpointToken(forceRotate: rotate))
            tokenMessage = success
        } catch {
            tokenMessage = nil
            tokenAlert = "\(failurePrefix): \(error.localizedDescription)"
        }
    }

    private func bootstrapTokenAfterInstall() {
        issueToken(rotate: false, success: "Token issued and dropped for daemon.", failurePrefix: "Token bootstrap failed")
    }

    private func reissueToken() {
        issueToken(rotate: true, success: "Token re-issued.", failurePrefix: "Token rotation failed")
    }

    private func ensureEndpointToken(forceRotate: Bool = false) throws -> String {
        let endpointName = NanoClawSettingsView.endpointName
        if let existing = endpointRegistry.endpoints.first(where: { $0.name == endpointName }) {
            if forceRotate { return try endpointRegistry.regenerateToken(for: existing.id) }
            if let token = endpointRegistry.token(for: existing) { return token }
            return try endpointRegistry.regenerateToken(for: existing.id)
        }
        let endpoint = OmniEndpoint(
            name: endpointName,
            host: "127.0.0.1",
            port: 7878,
            useTLS: false,
            tokenKeychainRef: "",
            repos: [],
            safeMode: false
        )
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        }
        let token = Data(bytes).base64EncodedString()
        try endpointRegistry.add(endpoint, token: token)
        return token
    }
}

private struct StatePill: View {
    let connector: ClawConnector?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connector?.status.dot ?? Color.gray)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        guard let connector else { return "Unknown" }
        switch connector.status {
        case .disconnected: return "Disconnected"
        case .connecting:
            if let detail = connector.detail, detail.lowercased().contains("qr") { return "Scan QR" }
            return "Connecting"
        case .connected:
            if let identity = connector.identity, !identity.isEmpty { return "Connected (\(identity))" }
            return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var accessibilityLabel: String {
        guard let connector else { return "Connector status unknown" }
        switch connector.status {
        case .connected:
            if let identity = connector.identity, !identity.isEmpty { return "\(connector.name) connected as \(identity)" }
            return "\(connector.name) connected"
        case .connecting: return "\(connector.name) connecting"
        case .disconnected: return "\(connector.name) disconnected"
        case .error(let msg): return "\(connector.name) error: \(msg)"
        }
    }
}

private struct ClawCard<Content: View>: View {
    let title: String
    let icon: String
    let iconTint: Color
    let content: Content

    init(title: String, icon: String, iconTint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.iconTint = iconTint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(iconTint)
                Text(title).font(.headline).foregroundStyle(.primary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}
