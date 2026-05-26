import Foundation
import AppKit
import SwiftUI
import os

private func parseISO8601(_ raw: String) -> Date? {
    if let date = DateFormatters.iso8601WithFractional.date(from: raw) { return date }
    return DateFormatters.iso8601Internet.date(from: raw)
}

enum ClawConnectionStatus: Equatable {
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

struct ClawConnector: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let tint: Color
    var status: ClawConnectionStatus = .disconnected
    var lastSeen: Date?
    var detail: String?
    var identity: String?
}

struct ClawStatusFile: Codable, Sendable {
    struct Mcp: Codable, Sendable {
        let connected: Bool
        let lastTickAt: Date?
        let error: String?
    }
    struct ConnectorState: Codable, Sendable {
        let state: String
        let detail: String?
        let identity: String?
        let lastEventAt: Date?
        let error: String?
    }
    struct Connectors: Codable, Sendable {
        let whatsapp: ConnectorState?
        let gmail: ConnectorState?
        let telegram: ConnectorState?
    }
    struct CronStatus: Codable, Sendable {
        let id: String
        let title: String
        let cron: String
        let prompt: String?
        let lastRun: Date?
        let lastStatus: String
        let error: String?
        let sinks: [String]
    }
    let version: Int
    let updatedAt: Date?
    let provider: String?
    let mcp: Mcp
    let connectors: Connectors?
    let whatsapp: ConnectorState?
    let gmail: ConnectorState?
    let crons: [CronStatus]?
}

struct JobRuntime: Equatable, Identifiable {
    let id: String
    let lastRun: Date?
    let lastStatus: String
    let error: String?
}

@MainActor
final class NanoClawService: ObservableObject {
    @Published var connectors: [ClawConnector] = NanoClawService.defaults
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastTick: Date?
    @Published private(set) var mcpConnected: Bool = false
    @Published private(set) var mcpError: String?
    @Published private(set) var launchAgentInstalled: Bool = ClawSignalBus.isLaunchAgentInstalled()
    @Published var whatsappQR: NSImage?
    @Published private(set) var provider: String = "claude"
    @Published private(set) var crons: [JobRuntime] = []

    private let logger = Logger(subsystem: "ai.geo", category: "NanoClawService")
    private let ioQueue = DispatchQueue(label: "ai.geo.nanoclaw.io", qos: .utility)

    private var statusWatcher: DispatchSourceFileSystemObject?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var pollTask: Task<Void, Never>?
    private var pendingRefresh: Task<Void, Never>?

    private var loggedDecodeFailureSignature: String?
    private var lastQRMtime: Date?

    private static let defaults: [ClawConnector] = [
        ClawConnector(id: "whatsapp", name: "WhatsApp", icon: "message.fill",
                      tint: Color(red: 0.07, green: 0.71, blue: 0.42)),
        ClawConnector(id: "gmail", name: "Gmail", icon: "envelope.fill",
                      tint: Color(red: 0.96, green: 0.55, blue: 0.13)),
        ClawConnector(id: "telegram", name: "Telegram", icon: "paperplane.fill",
                      tint: Color(red: 0.15, green: 0.59, blue: 0.91)),
    ]

    func start() {
        guard !isRunning else { return }
        isRunning = true
        try? ClawSignalBus.ensureSignalsDir()
        installStatusWatcher()
        installDirectoryWatcher()
        if statusWatcher == nil && directoryWatcher == nil {
            startPollingFallback()
        }
        scheduleRefresh()
    }

    func stop() {
        isRunning = false
        statusWatcher?.cancel(); statusWatcher = nil
        directoryWatcher?.cancel(); directoryWatcher = nil
        pollTask?.cancel(); pollTask = nil
        pendingRefresh?.cancel(); pendingRefresh = nil
    }

    private func updateConnector(id: String, _ mutate: (inout ClawConnector) -> Void) {
        guard let idx = connectors.firstIndex(where: { $0.id == id }) else { return }
        mutate(&connectors[idx])
    }

    func requestPair(_ id: String) {
        let signal: String
        switch id {
        case "whatsapp": signal = "request-pair-whatsapp"
        case "gmail": signal = "request-auth-gmail"
        case "telegram": signal = "request-pair-telegram"
        default: return
        }
        updateConnector(id: id) { $0.status = .connecting }
        do {
            try ClawSignalBus.writeSignal(name: signal)
        } catch {
            updateConnector(id: id) { $0.status = .error("Failed to write signal: \(error.localizedDescription)") }
        }
    }

    func requestDisconnect(_ id: String) {
        guard id == "whatsapp" || id == "gmail" || id == "telegram" else { return }
        do {
            try ClawSignalBus.writeSignal(name: "disconnect-\(id)")
            updateConnector(id: id) {
                $0.status = .disconnected
                $0.lastSeen = Date()
            }
        } catch {
            updateConnector(id: id) { $0.status = .error("Failed to write signal: \(error.localizedDescription)") }
        }
    }

    func bootstrapMcpToken(_ token: String) throws {
        try ClawSignalBus.writeBootstrapToken(token)
    }

    func refreshLaunchAgentInstalled() {
        launchAgentInstalled = ClawSignalBus.isLaunchAgentInstalled()
    }

    func installLaunchAgent() async throws -> ClawLaunchAgentInstallResult {
        let result: ClawLaunchAgentInstallResult = try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    continuation.resume(returning: try ClawSignalBus.installLaunchAgent())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        launchAgentInstalled = result.installed
        return result
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            await self?.refreshFromStatusFile()
        }
    }

    private func makeWatcher(
        path: String,
        eventMask: DispatchSource.FileSystemEvent,
        onEvent: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: eventMask, queue: ioQueue)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            onEvent(source.data)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func installStatusWatcher() {
        statusWatcher = makeWatcher(
            path: ClawSignalBus.statusFileURL().path,
            eventMask: [.write, .extend, .delete, .rename, .attrib]
        ) { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if data.contains(.delete) || data.contains(.rename) {
                    self.statusWatcher?.cancel()
                    self.statusWatcher = nil
                    self.installStatusWatcher()
                }
                self.scheduleRefresh()
            }
        }
    }

    private func installDirectoryWatcher() {
        directoryWatcher = makeWatcher(
            path: ClawSignalBus.baseDir().path,
            eventMask: [.write, .extend]
        ) { [weak self] _ in
            Task { @MainActor in
                if self?.statusWatcher == nil { self?.installStatusWatcher() }
                self?.scheduleRefresh()
            }
        }
    }

    private func startPollingFallback() {
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                await self.refreshFromStatusFile()
                if self.statusWatcher == nil {
                    self.installStatusWatcher()
                    if self.statusWatcher != nil {
                        self.directoryWatcher?.cancel()
                        self.directoryWatcher = nil
                        return
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func refreshFromStatusFile() async {
        let statusURL = ClawSignalBus.statusFileURL()
        let qrURL = ClawSignalBus.qrImageURL()

        let snapshot: StatusSnapshot = await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: Self.loadStatus(statusURL: statusURL, qrURL: qrURL))
            }
        }

        switch snapshot.status {
        case .missing:
            loggedDecodeFailureSignature = nil
            mcpConnected = false
            mcpError = nil
            lastTick = nil
            connectors = Self.defaults
            crons = []
            whatsappQR = nil
            lastQRMtime = nil
        case .decodeFailure(let signature):
            if loggedDecodeFailureSignature != signature {
                loggedDecodeFailureSignature = signature
                logger.error("Failed to decode status.json: \(signature, privacy: .public)")
            }
            return
        case .ok(let parsed):
            loggedDecodeFailureSignature = nil
            mcpConnected = parsed.mcp.connected
            mcpError = parsed.mcp.error
            if let tick = parsed.mcp.lastTickAt { lastTick = tick }
            if let raw = parsed.provider, !raw.isEmpty {
                provider = raw
            }
            let whatsapp = parsed.connectors?.whatsapp ?? parsed.whatsapp
            let gmail = parsed.connectors?.gmail ?? parsed.gmail
            let telegram = parsed.connectors?.telegram
            applyConnectorState(id: "whatsapp", remote: whatsapp)
            applyConnectorState(id: "gmail", remote: gmail)
            applyConnectorState(id: "telegram", remote: telegram)
            crons = (parsed.crons ?? []).map {
                JobRuntime(
                    id: $0.id,
                    lastRun: $0.lastRun,
                    lastStatus: $0.lastStatus,
                    error: $0.error
                )
            }
        }

        applyQR(qr: snapshot.qr)
    }

    private func applyConnectorState(id: String, remote: ClawStatusFile.ConnectorState?) {
        guard let idx = connectors.firstIndex(where: { $0.id == id }) else { return }
        guard let remote else {
            connectors[idx].status = .disconnected
            connectors[idx].detail = nil
            connectors[idx].identity = nil
            return
        }
        let status: ClawConnectionStatus
        switch remote.state {
        case "connected": status = .connected
        case "connecting", "qr", "authorizing": status = .connecting
        case "error": status = .error(remote.error ?? "Error")
        default: status = .disconnected
        }
        connectors[idx].status = status
        connectors[idx].detail = remote.detail
        connectors[idx].identity = remote.identity
        if let lastEvent = remote.lastEventAt { connectors[idx].lastSeen = lastEvent }
    }

    private func applyQR(qr: QRSnapshot) {
        let isPairing: Bool = {
            guard let connector = connectors.first(where: { $0.id == "whatsapp" }) else { return false }
            if case .connecting = connector.status { return true }
            return false
        }()

        guard isPairing, let data = qr.imageData else {
            whatsappQR = nil
            lastQRMtime = nil
            return
        }
        if qr.mtime != lastQRMtime {
            whatsappQR = NSImage(data: data)
            lastQRMtime = qr.mtime
        }
    }

    private struct StatusSnapshot: Sendable {
        enum Outcome: Sendable {
            case missing
            case decodeFailure(signature: String)
            case ok(ClawStatusFile)
        }
        let status: Outcome
        let qr: QRSnapshot
    }

    private struct QRSnapshot: Sendable {
        let imageData: Data?
        let mtime: Date?
    }

    nonisolated private static func loadStatus(statusURL: URL, qrURL: URL) -> StatusSnapshot {
        let outcome: StatusSnapshot.Outcome
        if let data = try? Data(contentsOf: statusURL) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let raw = try container.decode(String.self)
                    if let date = parseISO8601(raw) { return date }
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(raw)")
                }
                outcome = .ok(try decoder.decode(ClawStatusFile.self, from: data))
            } catch {
                outcome = .decodeFailure(signature: String(describing: error))
            }
        } else {
            outcome = .missing
        }

        let qr: QRSnapshot
        if let attrs = try? FileManager.default.attributesOfItem(atPath: qrURL.path),
           let mtime = attrs[.modificationDate] as? Date {
            qr = QRSnapshot(imageData: try? Data(contentsOf: qrURL), mtime: mtime)
        } else {
            qr = QRSnapshot(imageData: nil, mtime: nil)
        }

        return StatusSnapshot(status: outcome, qr: qr)
    }
}
