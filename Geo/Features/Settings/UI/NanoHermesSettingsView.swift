import AppKit
import SwiftUI

struct NanoHermesSettingsView: View {
    @EnvironmentObject private var endpointRegistry: EndpointRegistry

    @State private var daemonRunning: Bool = NanoHermesSettingsView.checkDaemonRunning()
    @State private var installRunning: Bool = false
    @State private var installLog: String = ""
    @State private var installError: String?
    @State private var tokenMessage: String?
    @State private var tokenAlert: String?

    private static let endpointName = "hermes"
    private static let launchAgentLabel = "ai.hermes.gateway"
    private var homeURL: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var soulURL: URL { homeURL.appendingPathComponent(".hermes/SOUL.md") }
    private var envURL: URL { homeURL.appendingPathComponent(".hermes/.env") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusRow
            installCard
            apiKeyCard
            filesCard
            tokenCard
        }
        .onAppear { refreshStatus() }
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
            Text("Hermes — 24/7 agent")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Hermes is the LaunchAgent successor to geo-claw. It bridges WhatsApp, Gmail, and Telegram, runs cron prompts, and dispatches subagents.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        let dotColor: Color = daemonRunning
            ? Color(red: 0.18, green: 0.78, blue: 0.46)
            : Color(white: 0.42)
        return HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(daemonRunning ? "Hermes gateway running" : "Hermes gateway stopped")
                    .font(.subheadline.weight(.medium))
                Text("LaunchAgent: \(NanoHermesSettingsView.launchAgentLabel)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { refreshStatus() }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var installCard: some View {
        HermesCard(title: "Install hermes", icon: "gearshape.2.fill", iconTint: .blue) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Runs the repo's hermes/install.sh to drop the gateway plist into ~/Library/LaunchAgents and start it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Install hermes") { runInstaller() }
                        .buttonStyle(.borderedProminent)
                        .disabled(installRunning)
                    if installRunning { ProgressView().controlSize(.small) }
                }
                if let installError {
                    Label(installError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !installLog.isEmpty {
                    ScrollView {
                        Text(installLog)
                            .font(.caption.monospaced())
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

    private var apiKeyCard: some View {
        HermesCard(title: "API server key", icon: "key.fill", iconTint: .purple) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Loaded from ~/.hermes/.env (API_SERVER_KEY). Used to authenticate the in-app Nano transport.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("API_SERVER_KEY", text: .constant(maskedKey))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
            }
        }
    }

    private var filesCard: some View {
        HermesCard(title: "Hermes files", icon: "doc.text.fill", iconTint: .orange) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("~/.hermes/SOUL.md").font(.caption.monospaced())
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(soulURL) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!FileManager.default.fileExists(atPath: soulURL.path))
                }
                HStack {
                    Text("~/.hermes/.env").font(.caption.monospaced())
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(envURL) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!FileManager.default.fileExists(atPath: envURL.path))
                }
            }
        }
    }

    private var tokenCard: some View {
        HermesCard(title: "MCP token", icon: "lock.fill", iconTint: .green) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Issue or rotate the token hermes uses to talk to Geo's MCP server (endpoint: \(NanoHermesSettingsView.endpointName)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Re-issue token") { reissueToken() }
                    .buttonStyle(.bordered)
                if let tokenMessage {
                    Text(tokenMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var maskedKey: String {
        guard let key = HermesEnv.shared.apiServerKey, !key.isEmpty else { return "" }
        if key.count <= 6 { return String(repeating: "•", count: key.count) }
        let prefix = key.prefix(2)
        let suffix = key.suffix(2)
        return "\(prefix)\(String(repeating: "•", count: max(4, key.count - 4)))\(suffix)"
    }

    private func refreshStatus() {
        daemonRunning = NanoHermesSettingsView.checkDaemonRunning()
    }

    private static func checkDaemonRunning() -> Bool {
        let process = Process()
        process.launchPath = "/bin/launchctl"
        process.arguments = ["list", launchAgentLabel]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func runInstaller() {
        installRunning = true
        installError = nil
        installLog = ""
        Task.detached(priority: .userInitiated) {
            let result = await runInstallScript()
            await MainActor.run {
                self.installLog = result.output
                self.installRunning = false
                if result.exitCode != 0 {
                    self.installError = result.output.isEmpty ? "Installer exited \(result.exitCode)" : nil
                }
                self.daemonRunning = NanoHermesSettingsView.checkDaemonRunning()
            }
        }
    }

    private struct InstallResult: Sendable {
        let exitCode: Int32
        let output: String
    }

    private func runInstallScript() async -> InstallResult {
        guard let scriptURL = locateInstallScript() else {
            return InstallResult(exitCode: -1, output: "Couldn't locate hermes/install.sh in the repo. Run it manually from a terminal.")
        }
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["bash", scriptURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return InstallResult(
                exitCode: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return InstallResult(exitCode: -1, output: "Failed to launch installer: \(error.localizedDescription)")
        }
    }

    private func locateInstallScript() -> URL? {
        let fm = FileManager.default
        let envPath = ProcessInfo.processInfo.environment["HERMES_INSTALL_SCRIPT"]
        if let envPath {
            let url = URL(fileURLWithPath: NSString(string: envPath).expandingTildeInPath)
            if fm.fileExists(atPath: url.path) { return url }
        }
        var roots: [URL] = []
        if let resource = Bundle.main.resourceURL { roots.append(resource) }
        roots.append(URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true))
        roots.append(Bundle.main.bundleURL.deletingLastPathComponent())
        for root in roots {
            var current = root.standardizedFileURL
            for _ in 0..<8 {
                let candidate = current.appendingPathComponent("hermes/install.sh", isDirectory: false)
                if fm.isReadableFile(atPath: candidate.path) { return candidate }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        return nil
    }

    private func reissueToken() {
        do {
            let token = try ensureEndpointToken(forceRotate: true)
            tokenMessage = "Token re-issued. Length: \(token.count) chars. Drop into ~/.hermes/.env as MCP_TOKEN if needed."
        } catch {
            tokenMessage = nil
            tokenAlert = "Token rotation failed: \(error.localizedDescription)"
        }
    }

    private func ensureEndpointToken(forceRotate: Bool = false) throws -> String {
        let endpointName = NanoHermesSettingsView.endpointName
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

private struct HermesCard<Content: View>: View {
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(iconTint)
                Text(title).font(.headline)
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
