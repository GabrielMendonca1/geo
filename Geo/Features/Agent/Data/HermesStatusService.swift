import Foundation
import AppKit
import SwiftUI
import os

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
    private var pollTask: Task<Void, Never>?
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
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: HermesStatusService.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        let installed = await Self.binaryOnPath()
        let daemonUp: Bool
        if installed {
            daemonUp = await Self.daemonRunning()
        } else {
            daemonUp = false
        }
        let statusData: Data?
        if installed {
            statusData = await Self.readStatusData()
        } else {
            statusData = nil
        }
        let parsed = statusData.flatMap { Self.parseStatusData($0) }
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

    private func applyStatus(_ obj: [String: Any]?) {
        guard let obj else { return }
        if let p = obj["provider"] as? String, !p.isEmpty {
            provider = p
        }
        if let qrPath = obj["whatsapp_qr_path"] as? String,
           !qrPath.isEmpty,
           FileManager.default.fileExists(atPath: qrPath),
           let img = NSImage(contentsOfFile: qrPath) {
            whatsappQR = img
        } else if (obj["whatsapp_qr_path"] as? String).map({ $0.isEmpty }) ?? false {
            whatsappQR = nil
        }
        if let chans = obj["channels"] as? [String: Any] {
            for i in connectors.indices {
                let id = connectors[i].id
                guard let entry = chans[id] as? [String: Any] else {
                    connectors[i].status = .disconnected
                    continue
                }
                let state = (entry["state"] as? String) ?? "disconnected"
                connectors[i].status = Self.parseStatus(state, detail: entry["detail"] as? String)
                connectors[i].identity = entry["identity"] as? String
                connectors[i].detail = entry["detail"] as? String
                if let lastMs = entry["last_seen_ms"] as? Double {
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
        let stream = await MCPClient.shared.callTool(
            spec: Self.hermesServerSpec(),
            name: "mcp_hermes_auth_set_telegram",
            input: .object(["token": .string(token)])
        )
        try await Self.drain(stream: stream)
    }

    private func runPair(_ id: String) async {
        let tool: String
        let cliFallback: String
        switch id {
        case "whatsapp":
            tool = "mcp_hermes_pair_whatsapp"
            cliFallback = "hermes auth add whatsapp"
        case "telegram":
            tool = "mcp_hermes_pair_telegram"
            cliFallback = "hermes auth add telegram"
        case "gmail":
            tool = "mcp_hermes_pair_gmail"
            cliFallback = "hermes auth add gmail"
        default:
            return
        }
        let stream = await MCPClient.shared.callTool(
            spec: Self.hermesServerSpec(),
            name: tool,
            input: .object([:])
        )
        do {
            try await Self.drain(stream: stream)
        } catch {
            logger.warning("requestPair(\(id, privacy: .public)) MCP failed: \(error.localizedDescription, privacy: .public); opening Terminal fallback.")
            Self.openTerminal(command: cliFallback)
            self.lastError = "MCP pair failed for \(id) — opened Terminal with `\(cliFallback)`."
        }
    }

    private func runDisconnect(_ id: String) async {
        let stream = await MCPClient.shared.callTool(
            spec: Self.hermesServerSpec(),
            name: "mcp_hermes_disconnect",
            input: .object(["channel": .string(id)])
        )
        do {
            try await Self.drain(stream: stream)
            for i in self.connectors.indices where self.connectors[i].id == id {
                self.connectors[i].status = .disconnected
                self.connectors[i].identity = nil
            }
        } catch {
            let cli = "hermes auth remove \(id)"
            logger.warning("requestDisconnect(\(id, privacy: .public)) MCP failed: \(error.localizedDescription, privacy: .public); opening Terminal fallback.")
            Self.openTerminal(command: cli)
            self.lastError = "MCP disconnect failed for \(id) — opened Terminal with `\(cli)`."
        }
    }

    static func hermesServerSpec() -> MCPServerSpec {
        let command = ProcessInfo.processInfo.environment["HERMES_MCP_COMMAND"] ?? "hermes"
        let argsRaw = ProcessInfo.processInfo.environment["HERMES_MCP_ARGS"] ?? "mcp"
        let arguments = argsRaw.split(separator: " ").map(String.init)
        return MCPServerSpec(name: "hermes", command: command, arguments: arguments, environment: nil)
    }

    static func drain(stream: AsyncThrowingStream<MCPEvent, Error>) async throws {
        for try await event in stream {
            if case .error(let message) = event {
                throw MCPClientError.toolError(message)
            }
            if case .result = event { return }
        }
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

    private static func readStatusData() async -> Data? {
        await Task.detached(priority: .utility) {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes/status.json")
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else {
                return nil
            }
            return data
        }.value
    }

    private static func parseStatusData(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func openTerminal(command: String) {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\""
        Task.detached(priority: .userInitiated) {
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            try? task.run()
        }
    }
}
