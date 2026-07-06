import Foundation

struct TermWinsize: Decodable {
    let cols: Int
    let rows: Int
    let shared: Bool
}

@MainActor
final class TerminalViewModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var reconnecting = false
    @Published private(set) var cols = 80
    @Published private(set) var rows = 24
    @Published private(set) var session: String
    @Published var errorMessage: String?

    let client: BridgeClient
    var onBytes: (([UInt8]) -> Void)?
    var onReset: (() -> Void)?
    var onToggleKeyboard: (() -> Void)?

    private var streamTask: Task<Void, Never>?
    private var streamGeneration = 0
    private var resizeTask: Task<Void, Never>?

    init(session: String, client: BridgeClient = .shared) {
        self.session = session
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

    func switchTo(_ name: String) {
        guard name != session else { return }
        disconnect()
        session = name
        onReset?()
        connect()
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let body = Data(Data(bytes).base64EncodedString().utf8)
        let path = "/term/input?session=\(session)"
        Task { [client] in _ = try? await client.postData(path, body: body, token: BridgeConfig.termToken) }
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
        let path = "/term/winsize?session=\(session)"
        guard let data = try? await client.getData(path, token: BridgeConfig.termToken) else { return nil }
        return try? JSONDecoder().decode(TermWinsize.self, from: data)
    }

    private func sendResize() {
        let body = try? JSONSerialization.data(withJSONObject: ["rows": rows, "cols": cols])
        let path = "/term/resize?session=\(session)"
        Task { [client] in _ = try? await client.postData(path, body: body, token: BridgeConfig.termToken) }
    }

    private func runStreamLoop(generation: Int) async {
        var backoff: UInt64 = 500_000_000
        while generation == streamGeneration && !Task.isCancelled {
            let didInit = await runStream(generation: generation)
            if generation != streamGeneration || Task.isCancelled { break }
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

    private func runStream(generation: Int) async -> Bool {
        errorMessage = nil
        var didInit = false
        do {
            let path = "/term/stream?session=\(session)"
            for try await message in client.stream(path, token: BridgeConfig.termToken) {
                if generation != streamGeneration || Task.isCancelled { break }
                if !didInit {
                    didInit = true
                    connected = true
                    reconnecting = false
                    sendResize()
                }
                if message.event == "done" { break }
                if let data = Data(base64Encoded: message.data) {
                    onBytes?([UInt8](data))
                }
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
        if generation == streamGeneration { connected = false }
        return didInit
    }
}
