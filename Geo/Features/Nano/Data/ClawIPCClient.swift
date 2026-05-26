import Foundation
import Network
import os

private let ipcLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "ClawIPCClient")

enum ClawIPCError: Error, LocalizedError {
    case notConnected
    case socketMissing
    case encodeFailed
    case decodeFailed(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to claw daemon"
        case .socketMissing: return "Claw IPC socket missing — is geo-claw running?"
        case .encodeFailed: return "Failed to encode IPC request"
        case .decodeFailed(let m): return "Failed to decode daemon response: \(m)"
        case .remote(let m): return m
        }
    }
}

struct HistoryEntry: Sendable, Identifiable {
    let id: Int
    let channelId: String
    let role: String
    let text: String
    let ts: Int64
}

struct ChannelSummary: Sendable, Identifiable {
    var id: String { channelId }
    let channelId: String
    let lastTs: Int64
    let msgCount: Int
}

actor ClawIPCClient {
    static let shared = ClawIPCClient()

    private var connection: NWConnection?
    private var readBuffer = Data()
    private var nextId: Int = 1
    private var streamPending: [Int: AsyncThrowingStream<TurnEvent, Error>.Continuation] = [:]
    private var requestPending: [Int: CheckedContinuation<Any, Error>] = [:]

    private let socketPath: String

    init(socketPath: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.socketPath = socketPath ?? "\(home)/Library/Application Support/GeoClaw/claw-ipc.sock"
    }

    private func ensureConnected() async throws {
        if let c = connection, case .ready = c.state { return }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ClawIPCError.socketMissing
        }
        let endpoint: NWEndpoint = .unix(path: socketPath)
        let params = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: params)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let err):
                    if !resumed { resumed = true; cont.resume(throwing: err) }
                case .cancelled:
                    if !resumed { resumed = true; cont.resume(throwing: ClawIPCError.notConnected) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        self.connection = conn
        startReadLoop()
    }

    private nonisolated func startReadLoop() {
        Task { await self.readLoop() }
    }

    private func readLoop() async {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty {
                    await self.feedBytes(data)
                }
                if isComplete || error != nil {
                    await self.handleDisconnect(error: error)
                } else {
                    await self.readLoop()
                }
            }
        }
    }

    private func feedBytes(_ data: Data) {
        readBuffer.append(data)
        while let nlIndex = readBuffer.firstIndex(of: 0x0A) {
            let line = Data(readBuffer.prefix(upTo: nlIndex))
            readBuffer.removeSubrange(readBuffer.startIndex...nlIndex)
            if line.isEmpty { continue }
            routeLine(line)
        }
    }

    private func routeLine(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            ipcLogger.warning("ipc: invalid JSON line")
            return
        }
        let idValue: Int?
        if let n = obj["id"] as? Int { idValue = n }
        else if let s = obj["id"] as? String, let n = Int(s) { idValue = n }
        else { idValue = nil }
        guard let id = idValue else { return }

        if let streamCont = streamPending[id] {
            guard let event = TurnEventDecoder.decode(line: line) else { return }
            switch event {
            case .done, .failure:
                streamCont.yield(event)
                streamCont.finish()
                streamPending.removeValue(forKey: id)
            default:
                streamCont.yield(event)
            }
            return
        }

        if let reqCont = requestPending.removeValue(forKey: id) {
            if let err = obj["error"] as? String {
                reqCont.resume(throwing: ClawIPCError.remote(err))
            } else {
                reqCont.resume(returning: obj["result"] ?? NSNull())
            }
        }
    }

    private func handleDisconnect(error: NWError?) {
        if let error {
            ipcLogger.warning("ipc disconnect: \(error.localizedDescription)")
        }
        connection?.cancel()
        connection = nil
        readBuffer.removeAll()
        let disconnectMsg = error?.localizedDescription ?? "daemon disconnected"
        for (_, cont) in streamPending {
            cont.yield(.failure(message: disconnectMsg))
            cont.finish()
        }
        streamPending.removeAll()
        for (_, cont) in requestPending {
            cont.resume(throwing: ClawIPCError.remote(disconnectMsg))
        }
        requestPending.removeAll()
    }

    private func writeRequest(id: Int, method: String, params: [String: Any]) async throws {
        guard let conn = connection else { throw ClawIPCError.notConnected }
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]) else {
            throw ClawIPCError.encodeFailed
        }
        data.append(0x0A)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    struct IPCAttachment {
        let type: String   // "image" | "file"
        let mediaType: String
        let base64: String
        let name: String?
    }

    func runTurn(
        channelId: String? = nil,
        userText: String,
        attachments: [IPCAttachment] = []
    ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        try await ensureConnected()
        let id = nextId
        nextId += 1

        var params: [String: Any] = ["userText": userText]
        if let channelId, !channelId.isEmpty { params["channelId"] = channelId }
        if !attachments.isEmpty {
            params["attachments"] = attachments.map { a -> [String: Any] in
                var dict: [String: Any] = [
                    "type": a.type,
                    "mediaType": a.mediaType,
                    "base64": a.base64,
                ]
                if let name = a.name { dict["name"] = name }
                return dict
            }
        }

        let (stream, cont) = AsyncThrowingStream<TurnEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        streamPending[id] = cont
        do {
            try await writeRequest(id: id, method: "llm.run_turn", params: params)
        } catch {
            streamPending.removeValue(forKey: id)
            cont.finish(throwing: error)
        }
        return stream
    }

    @discardableResult
    func cancel(channelId: String = "main") async throws -> Bool {
        try await ensureConnected()
        let id = nextId
        nextId += 1
        let raw: Any = try await withCheckedThrowingContinuation { cont in
            requestPending[id] = cont
            Task {
                do {
                    try await writeRequest(id: id, method: "llm.cancel", params: ["channelId": channelId])
                } catch {
                    if let pending = await self.requestPending.removeValue(forKey: id) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }
        if let obj = raw as? [String: Any], let c = obj["cancelled"] as? Bool { return c }
        return false
    }

    @discardableResult
    func resetSession(channelId: String = "main") async throws -> (droppedSession: Bool, clearedMessages: Int) {
        try await ensureConnected()
        let id = nextId
        nextId += 1
        let raw: Any = try await withCheckedThrowingContinuation { cont in
            requestPending[id] = cont
            Task {
                do {
                    try await writeRequest(id: id, method: "llm.reset_session", params: ["channelId": channelId])
                } catch {
                    if let pending = await self.requestPending.removeValue(forKey: id) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }
        guard let obj = raw as? [String: Any] else {
            return (false, 0)
        }
        let dropped = (obj["droppedSession"] as? Bool) ?? false
        let cleared = (obj["clearedMessages"] as? Int) ?? ((obj["clearedMessages"] as? NSNumber)?.intValue ?? 0)
        return (dropped, cleared)
    }

    func listChannels(prefix: String = "", limit: Int = 50) async throws -> [ChannelSummary] {
        try await ensureConnected()
        let id = nextId
        nextId += 1
        let raw: Any = try await withCheckedThrowingContinuation { cont in
            requestPending[id] = cont
            Task {
                do {
                    try await writeRequest(id: id, method: "conversations.list_channels", params: ["prefix": prefix, "limit": limit])
                } catch {
                    if let pending = await self.requestPending.removeValue(forKey: id) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { row in
            guard let channelId = row["channelId"] as? String else { return nil }
            let ts = (row["lastTs"] as? Int64) ?? ((row["lastTs"] as? NSNumber)?.int64Value ?? 0)
            let count = (row["msgCount"] as? Int) ?? ((row["msgCount"] as? NSNumber)?.intValue ?? 0)
            return ChannelSummary(channelId: channelId, lastTs: ts, msgCount: count)
        }
    }

    func getHistory(channelId: String, limit: Int = 50) async throws -> [HistoryEntry] {
        try await ensureConnected()
        let id = nextId
        nextId += 1
        let raw: Any = try await withCheckedThrowingContinuation { cont in
            requestPending[id] = cont
            Task {
                do {
                    try await writeRequest(id: id, method: "conversations.get_history", params: ["channelId": channelId, "limit": limit])
                } catch {
                    if let pending = await self.requestPending.removeValue(forKey: id) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { row in
            guard let rowId = (row["id"] as? Int) ?? (row["id"] as? NSNumber)?.intValue,
                  let chId = row["channel_id"] as? String,
                  let role = row["role"] as? String,
                  let contentJson = row["content"] as? String,
                  let ts = (row["ts"] as? Int64) ?? (row["ts"] as? NSNumber)?.int64Value else {
                return nil
            }
            let text: String = {
                if let data = contentJson.data(using: .utf8),
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let t = obj["text"] as? String {
                    return t
                }
                return contentJson
            }()
            return HistoryEntry(id: rowId, channelId: chId, role: role, text: text, ts: ts)
        }
    }

    private func removeRequestPending(_ id: Int) {
        requestPending.removeValue(forKey: id)
    }
}
