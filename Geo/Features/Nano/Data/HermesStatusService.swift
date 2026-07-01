import Foundation
import AppKit
import SwiftUI
import os

final class Poller {
    private var task: Task<Void, Never>?
    private let interval: UInt64
    private let tick: @Sendable () async -> Void

    init(interval: UInt64, tick: @escaping @Sendable () async -> Void) {
        self.interval = interval
        self.tick = tick
    }

    func start() {
        guard task == nil else { return }
        let interval = self.interval
        let tick = self.tick
        task = Task {
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

struct HermesStatus: Codable {
    struct Channel: Codable {
        let state: String?
        let detail: String?
        let identity: String?
        let last_seen_ms: Double?
    }

    struct Cron: Codable {
        let id: String?
        let title: String?
        let schedule: String?
        let prompt: String?
        let last_run_at: String?
        let last_status: String?
        let last_error: String?
    }

    let provider: String?
    let whatsapp_qr_path: String?
    let channels: [String: Channel]?
    let crons: [Cron]?

    private nonisolated static let statusURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".hermes/status.json")

    nonisolated static func read() async -> HermesStatus? {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: statusURL.path),
                  let data = try? Data(contentsOf: statusURL) else {
                return nil
            }
            return try? JSONDecoder().decode(HermesStatus.self, from: data)
        }.value
    }
}

enum HermesConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .error(let msg): return msg
        }
    }

    var dot: Color {
        switch self {
        case .connected: return Color(red: 0.18, green: 0.78, blue: 0.46)
        case .connecting: return Color(red: 0.99, green: 0.78, blue: 0.22)
        case .disconnected: return Color(white: 0.42)
        case .error: return Color(red: 0.95, green: 0.32, blue: 0.32)
        }
    }
}

struct HermesConnector: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let tint: Color
    var status: HermesConnectionStatus = .disconnected
    var lastSeen: Date?
    var detail: String?
    var identity: String?
}

@MainActor
final class HermesStatusService: ObservableObject {
    @Published var connectors: [HermesConnector] = HermesStatusService.defaults
    @Published private(set) var mcpConnected: Bool = false
    @Published private(set) var mcpError: String?
    @Published private(set) var lastTick: Date?
    @Published private(set) var provider: String = "claude"
    @Published private(set) var crons: [JobRuntime] = []
    @Published var whatsappQR: NSImage?
    @Published private(set) var lastError: String?
    @Published private(set) var binaryInstalled: Bool = false
    @Published private(set) var setupActionInFlight: Bool = false

    enum SetupState: Equatable {
        case running
        case installedNotRunning
        case notInstalled
    }

    var setupState: SetupState {
        if !binaryInstalled { return .notInstalled }
        if !mcpConnected { return .installedNotRunning }
        return .running
    }

    private let logger = Logger(subsystem: "ai.geo", category: "HermesStatusService")
    private lazy var poller = Poller(interval: Self.pollInterval) { [weak self] in
        await self?.pollOnce()
    }
    private static let launchAgentLabel = "ai.hermes.gateway"
    private static let pollInterval: UInt64 = 5_000_000_000

    static let defaults: [HermesConnector] = [
        HermesConnector(id: "whatsapp", name: "WhatsApp", icon: "message.fill",
                        tint: Color(red: 0.07, green: 0.71, blue: 0.42)),
        HermesConnector(id: "gmail", name: "Gmail", icon: "envelope.fill",
                        tint: Color(red: 0.96, green: 0.55, blue: 0.13)),
        HermesConnector(id: "telegram", name: "Telegram", icon: "paperplane.fill",
                        tint: Color(red: 0.15, green: 0.59, blue: 0.91)),
    ]

    func start() {
        poller.start()
    }

    func stop() {
        poller.stop()
    }

    private func pollOnce() async {
        let installed = await Self.binaryOnPath()
        let daemonUp: Bool
        if installed {
            daemonUp = await Self.daemonRunning()
        } else {
            daemonUp = false
        }
        let parsed: HermesStatus?
        if installed {
            parsed = await HermesStatus.read()
        } else {
            parsed = nil
        }
        self.binaryInstalled = installed
        self.applyDaemon(daemonUp: daemonUp)
        self.applyStatus(parsed)
        self.lastTick = Date()
    }

    func installHermes() {
        guard !setupActionInFlight else { return }
        setupActionInFlight = true
        let cmd = "curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash"
        Self.openTerminal(command: cmd)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { self?.setupActionInFlight = false }
        }
    }

    func startGateway() {
        guard !setupActionInFlight else { return }
        setupActionInFlight = true
        Task { [weak self] in
            let result = await Self.runHermesGatewayStart()
            await MainActor.run {
                guard let self else { return }
                if let err = result {
                    self.lastError = err
                }
                self.setupActionInFlight = false
            }
        }
    }

    private static func runHermesGatewayStart() async -> String? {
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.launchPath = "/bin/zsh"
            proc.arguments = ["-lc", "hermes gateway start"]
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 { return nil as String? }
                let data = try errPipe.fileHandleForReading.readToEnd() ?? Data()
                let s = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return s.isEmpty ? "hermes gateway start failed" : s
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    private static func binaryOnPath() async -> Bool {
        await Task.detached(priority: .utility) {
            let proc = Process()
            proc.launchPath = "/bin/zsh"
            proc.arguments = ["-lc", "command -v hermes"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    private func applyDaemon(daemonUp: Bool) {
        if daemonUp {
            if !mcpConnected { mcpConnected = true }
            mcpError = nil
        } else {
            mcpConnected = false
            mcpError = "launchctl: \(Self.launchAgentLabel) not running"
            for i in connectors.indices {
                if case .connected = connectors[i].status { continue }
                connectors[i].status = .disconnected
            }
        }
    }

    private func applyStatus(_ status: HermesStatus?) {
        guard let status else { return }
        if let p = status.provider, !p.isEmpty {
            provider = p
        }
        if let qrPath = status.whatsapp_qr_path,
           !qrPath.isEmpty,
           FileManager.default.fileExists(atPath: qrPath),
           let img = NSImage(contentsOfFile: qrPath) {
            whatsappQR = img
        } else if status.whatsapp_qr_path.map({ $0.isEmpty }) ?? false {
            whatsappQR = nil
        }
        if let chans = status.channels {
            for i in connectors.indices {
                let id = connectors[i].id
                guard let entry = chans[id] else {
                    connectors[i].status = .disconnected
                    continue
                }
                let state = entry.state ?? "disconnected"
                connectors[i].status = Self.parseStatus(state, detail: entry.detail)
                connectors[i].identity = entry.identity
                connectors[i].detail = entry.detail
                if let lastMs = entry.last_seen_ms {
                    connectors[i].lastSeen = Date(timeIntervalSince1970: lastMs / 1000)
                }
            }
        }
    }

    private static func parseStatus(_ raw: String, detail: String?) -> HermesConnectionStatus {
        switch raw.lowercased() {
        case "connected", "ready", "authenticated": return .connected
        case "connecting", "pairing", "qr", "scan": return .connecting
        case "error", "failed":
            return .error(detail ?? "error")
        default: return .disconnected
        }
    }

    func requestPair(_ id: String) {
        lastError = nil
        for i in connectors.indices where connectors[i].id == id {
            connectors[i].status = .connecting
        }
        Task { [weak self] in
            await self?.runPair(id)
        }
    }

    func requestDisconnect(_ id: String) {
        lastError = nil
        Task { [weak self] in
            await self?.runDisconnect(id)
        }
    }

    func saveTelegramBotToken(_ token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "HermesStatusService", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty token"])
        }
        let result = await Task.detached(priority: .userInitiated) { () -> String? in
            Self.upsertEnvKey(file: Self.hermesEnvURL(), key: "TELEGRAM_BOT_TOKEN", value: trimmed)
        }.value
        if let err = result {
            throw NSError(domain: "HermesStatusService", code: 2, userInfo: [NSLocalizedDescriptionKey: err])
        }
        await Self.kickstartGateway()
    }

    private func runPair(_ id: String) async {
        let cli: String
        switch id {
        case "whatsapp":
            cli = "hermes whatsapp"
        case "telegram":
            cli = "hermes auth add telegram --type oauth"
        case "gmail":
            cli = "hermes auth add gmail --type oauth"
        default:
            return
        }
        Self.openTerminal(command: cli)
    }

    private func runDisconnect(_ id: String) async {
        let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            let proc = Process()
            proc.launchPath = "/bin/zsh"
            proc.arguments = ["-lc", "hermes auth logout \(id) || hermes auth remove \(id)"]
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (proc.terminationStatus, stderr)
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value
        if result.0 == 0 {
            for i in self.connectors.indices where self.connectors[i].id == id {
                self.connectors[i].status = .disconnected
                self.connectors[i].identity = nil
            }
            self.lastError = nil
        } else {
            logger.warning("disconnect(\(id, privacy: .public)) failed: \(result.1, privacy: .public)")
            self.lastError = "hermes auth logout \(id) failed: \(result.1.isEmpty ? "exit \(result.0)" : result.1)"
        }
    }

    private nonisolated static func hermesEnvURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/.env")
    }

    private nonisolated static func upsertEnvKey(file: URL, key: String, value: String) -> String? {
        let line = "\(key)=\(value)"
        let existing: String
        if FileManager.default.fileExists(atPath: file.path) {
            existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        } else {
            existing = ""
        }
        var output: [String] = []
        var replaced = false
        for raw in existing.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key)=") || trimmed.hasPrefix("# \(key)=") {
                output.append(line)
                replaced = true
            } else {
                output.append(raw)
            }
        }
        if !replaced {
            if !output.isEmpty, !(output.last?.isEmpty ?? true) {
                output.append("")
            }
            output.append(line)
        }
        do {
            try output.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "write .env failed: \(error.localizedDescription)"
        }
    }

    private nonisolated static func kickstartGateway() async {
        await Task.detached(priority: .utility) {
            let proc = Process()
            proc.launchPath = "/bin/zsh"
            let uid = getuid()
            proc.arguments = ["-lc", "launchctl kickstart -k gui/\(uid)/ai.hermes.gateway"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }.value
    }

    private static func daemonRunning() async -> Bool {
        await Task.detached(priority: .utility) {
            let proc = Process()
            proc.launchPath = "/bin/launchctl"
            proc.arguments = ["list", launchAgentLabel]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    private static func openTerminal(command: String) {
        Task.detached(priority: .userInitiated) {
            _ = await Self.openTerminalAsync(command: command)
        }
    }

    @discardableResult
    private static func openTerminalAsync(command: String) async -> String? {
        // Write a .command shell script and open it. macOS opens .command files in
        // Terminal.app automatically — no AppleScript / Automation permission needed.
        let tmpDir = FileManager.default.temporaryDirectory
        let scriptURL = tmpDir.appendingPathComponent("hermes-\(UUID().uuidString.prefix(8)).command")
        let body = """
        #!/bin/bash
        set -e
        echo
        echo "[geo] running: \(command)"
        echo
        \(command)
        echo
        echo "[geo] done. press return to close."
        read
        """
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            return "couldn't write install script: \(error.localizedDescription)"
        }
        let opened = await MainActor.run {
            NSWorkspace.shared.open(scriptURL)
        }
        if !opened {
            // Fall back to AppleScript if NSWorkspace declines (Terminal.app missing
            // a default association, for example).
            let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "tell application \"Terminal\" to do script \"\(escaped)\""
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            let errPipe = Pipe()
            task.standardError = errPipe
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    let data = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let stderr = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return stderr.isEmpty ? "couldn't open Terminal" : stderr
                }
            } catch {
                return "couldn't launch osascript: \(error.localizedDescription)"
            }
        }
        return nil
    }
}
