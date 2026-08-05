import Foundation

struct TermWinsize: Decodable {
    let cols: Int
    let rows: Int
    let shared: Bool
}

struct TermSessions: Decodable {
    let sessions: [String]
}

struct TermUploadResult: Decodable {
    let path: String
}

enum UploadName {
    static func sanitized(_ raw: String, fallback: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let base = (raw as NSString).lastPathComponent
        var cleaned = String(base.map { allowed.contains($0) ? $0 : "_" })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 80 { cleaned = String(cleaned.suffix(80)) }
        return cleaned.isEmpty ? fallback : cleaned
    }
}

@MainActor
final class TerminalViewModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var reconnecting = false
    @Published private(set) var cols = 80
    @Published private(set) var rows = 24
    @Published private(set) var session: String
    @Published var terminalOrigin: String = "vm"
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published private(set) var selectionMode = false

    let client: any BridgeAPI
    var onBytes: (([UInt8], Bool) -> Void)?
    var onReset: (() -> Void)?
    var onToggleKeyboard: (() -> Void)?
    var onShowKeyboard: (() -> Void)?
    var onPaste: (() -> Void)?
    var onCopySelection: (() -> Void)?
    var onSelectionMode: ((Bool) -> Void)?

    private var streamTask: Task<Void, Never>?
    private var streamGeneration = 0
    private var resizeTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var inputReconnectPending = false

    init(session: String, origin: String = "vm", client: any BridgeAPI = BridgeClient.shared) {
        self.session = session
        self.terminalOrigin = origin
        self.client = client
    }

    func connect() {
        guard streamTask == nil else { return }
        streamGeneration &+= 1
        let generation = streamGeneration
        streamTask = Task { [weak self] in await self?.runStreamLoop(generation: generation) }
    }

    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        connected = false
        reconnecting = false
    }

    func reconnect() {
        disconnect()
        onReset?()
        connect()
    }

    func switchTo(_ name: String, origin: String) {
        guard name != session || origin != terminalOrigin else { return }
        disconnect()
        session = name
        terminalOrigin = origin
        onReset?()
        connect()
    }

    func killSession(_ name: String) {
        let path = BridgeEndpoint.termKill(session: endpointSession(for: name)).path
        Task { [client] in
            _ = try? await client.postData(path, body: nil, token: BridgeConfig.termToken)
        }
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let body = Data(Data(bytes).base64EncodedString().utf8)
        let path = BridgeEndpoint.termInput(session: endpointSession).path
        Task { [weak self, client] in
            do {
                _ = try await client.postData(path, body: body, token: BridgeConfig.termToken)
            } catch BridgeError.server(let status, _) where status == 409 {
                self?.handleDetachedInput()
            } catch {
                self?.flashNotice("input falhou")
            }
        }
    }

    func setSelectionMode(_ on: Bool) {
        guard selectionMode != on else { return }
        selectionMode = on
        onSelectionMode?(on)
    }

    func flashUploadFailure() {
        flashNotice("upload falhou")
    }

    func upload(_ data: Data, filename: String) async {
        guard !data.isEmpty else {
            flashNotice("upload falhou")
            return
        }
        guard data.count <= 32 * 1024 * 1024 else {
            flashNotice("arquivo grande demais")
            return
        }
        notice = "enviando \(filename)"
        noticeTask?.cancel()
        do {
            let response = try await client.uploadFile(
                BridgeEndpoint.termUpload.path,
                body: data,
                filename: filename,
                token: BridgeConfig.termToken
            )
            let result = try JSONDecoder().decode(TermUploadResult.self, from: response)
            send(Array(result.path.utf8))
            flashNotice("enviado")
        } catch {
            flashNotice("upload falhou")
        }
    }

    func fetchSessions() async -> [String]? {
        guard let data = try? await client.getData(BridgeEndpoint.termList.path, token: BridgeConfig.termToken) else {
            return nil
        }
        return try? JSONDecoder().decode(TermSessions.self, from: data).sessions
    }

    private func handleDetachedInput() {
        guard !reconnecting, !inputReconnectPending else { return }
        inputReconnectPending = true
        flashNotice("reconectando")
        reconnect()
    }

    private func flashNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func updateSize(rows: Int, cols: Int) {
        guard rows > 0, cols > 0, rows != self.rows || cols != self.cols else { return }
        self.rows = rows
        self.cols = cols
        guard connected else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.sendResize()
        }
    }

    func fetchWinsize() async -> TermWinsize? {
        let path = BridgeEndpoint.termWinsize(session: endpointSession).path
        guard let data = try? await client.getData(path, token: BridgeConfig.termToken) else { return nil }
        return try? JSONDecoder().decode(TermWinsize.self, from: data)
    }

    private func sendResize() {
        let body = try? JSONSerialization.data(withJSONObject: ["rows": rows, "cols": cols])
        let path = BridgeEndpoint.termResize(session: endpointSession).path
        Task { [client] in _ = try? await client.postData(path, body: body, token: BridgeConfig.termToken) }
    }

    private func runStreamLoop(generation: Int) async {
        var backoff: UInt64 = 500_000_000
        while generation == streamGeneration && !Task.isCancelled {
            let (didInit, closedByServer) = await runStream(generation: generation)
            if generation != streamGeneration || Task.isCancelled { break }
            if closedByServer { break }
            reconnecting = true
            if didInit { backoff = 500_000_000 }
            do { try await Task.sleep(nanoseconds: backoff) } catch { break }
            backoff = min(backoff &* 2, 5_000_000_000)
            onReset?()
        }
        guard generation == streamGeneration else { return }
        connected = false
        reconnecting = false
        streamTask = nil
    }

    private func runStream(generation: Int) async -> (didInit: Bool, closedByServer: Bool) {
        errorMessage = nil
        var didInit = false
        var closedByServer = false
        do {
            let sseClient = SSEClient(
                client: client,
                path: BridgeEndpoint.termStream(session: endpointSession).path,
                token: BridgeConfig.termToken
            )
            for try await message in sseClient.stream() {
                if generation != streamGeneration || Task.isCancelled { break }
                if !didInit {
                    didInit = true
                    connected = true
                    reconnecting = false
                    inputReconnectPending = false
                    sendResize()
                }
                if message.event == "done" {
                    closedByServer = true
                    break
                }
                if let data = Data(base64Encoded: message.data) {
                    onBytes?([UInt8](data), message.event == "replay")
                }
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
        if generation == streamGeneration {
            connected = false
            if closedByServer { errorMessage = "sessão encerrada" }
        }
        return (didInit, closedByServer)
    }

    private var endpointSession: String {
        endpointSession(for: session)
    }

    private func endpointSession(for name: String) -> String {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        let origin = parts.count == 2 ? parts[0] : terminalOrigin
        if origin == "mac" { return "mac" }
        return parts.count == 2 ? parts[1] : name
    }
}
