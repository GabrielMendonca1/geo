import Foundation
import os

private let hermesLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "HermesHTTPTransport")

enum HermesTransportError: Error, LocalizedError {
    case missingAPIKey
    case encodeFailed
    case decodeFailed(String)
    case http(status: Int, body: String)
    case malformedSSE
    case noRunID

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Hermes API key missing (~/.hermes/.env API_SERVER_KEY)"
        case .encodeFailed: return "Failed to encode hermes request body"
        case .decodeFailed(let m): return "Failed to decode hermes response: \(m)"
        case .http(let s, let b): return "Hermes \(s): \(b)"
        case .malformedSSE: return "Malformed SSE stream from hermes"
        case .noRunID: return "Hermes did not return a run id"
        }
    }
}

struct SSEFrame: Sendable, Equatable {
    let event: String?
    let data: String
}

enum SSELineParser {
    enum Line: Equatable {
        case eventName(String)
        case dataLine(String)
        case dispatch
        case comment
        case unknown
    }

    static func parse(_ line: String) -> Line {
        if line.isEmpty { return .dispatch }
        if line.hasPrefix(":") { return .comment }
        if line.hasPrefix("event:") {
            let v = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            return .eventName(v)
        }
        if line.hasPrefix("data:") {
            let v = line.dropFirst("data:".count)
            let cleaned = v.hasPrefix(" ") ? String(v.dropFirst()) : String(v)
            return .dataLine(cleaned)
        }
        return .unknown
    }
}

enum HermesEventMapper {
    static func map(frame: SSEFrame) -> TurnEvent? {
        guard let data = frame.data.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let name = frame.event ?? (obj["event"] as? String) ?? (obj["type"] as? String) ?? ""
        switch name {
        case "text", "text.delta", "delta":
            let delta = (obj["delta"] as? String) ?? (obj["text"] as? String) ?? ""
            return .text(delta: delta)
        case "tool_use", "tool.use":
            let id = (obj["tool_use_id"] as? String) ?? (obj["id"] as? String) ?? ""
            let toolName = (obj["name"] as? String) ?? ""
            let input = jsonValue(from: obj["input"])
            return .toolUse(id: id, name: toolName, input: input)
        case "tool_result", "tool.result":
            let id = (obj["tool_use_id"] as? String) ?? (obj["id"] as? String) ?? ""
            let content = jsonValue(from: obj["content"])
            let isError = (obj["is_error"] as? Bool) ?? (obj["isError"] as? Bool) ?? false
            return .toolResult(id: id, content: content, isError: isError)
        case "tool_partial", "tool.partial":
            let id = (obj["tool_use_id"] as? String) ?? (obj["call_id"] as? String) ?? (obj["id"] as? String) ?? ""
            let partial = jsonValue(from: obj["partial"] ?? obj["content"])
            return .toolPartial(callID: id, partial: partial)
        case "agent_dispatch", "agent.dispatch":
            let wsID = (obj["workspace_id"] as? String) ?? (obj["workspaceId"] as? String) ?? ""
            let status = (obj["status"] as? String) ?? "running"
            let lastLine = (obj["last_line"] as? String) ?? (obj["lastLine"] as? String)
            return .agentDispatch(workspaceID: wsID, status: status, lastLine: lastLine)
        case "done", "complete", "completion":
            let reply = obj["reply"] as? String
            return .done(reply: reply)
        case "error", "failure":
            let msg = (obj["message"] as? String) ?? (obj["error"] as? String) ?? "unknown error"
            return .failure(message: msg)
        default:
            return nil
        }
    }

    private static func jsonValue(from any: Any?) -> JSONValue {
        guard let any else { return .null }
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed]) else {
            return .null
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
}

private final class SSEDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<SSEFrame, Error>.Continuation
    private let lock = NSLock()
    private var buffer = Data()
    private var pendingEvent: String?
    private var pendingData: [String] = []
    private var receivedHTTPError: (status: Int, body: Data)?

    init(continuation: AsyncThrowingStream<SSEFrame, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            lock.lock()
            receivedHTTPError = (http.statusCode, Data())
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if receivedHTTPError != nil {
            receivedHTTPError?.body.append(data)
            lock.unlock()
            return
        }
        buffer.append(data)
        let frames = drainFramesLocked()
        lock.unlock()
        for frame in frames {
            continuation.yield(frame)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let httpError = receivedHTTPError
        let leftover = buffer
        buffer.removeAll(keepingCapacity: false)
        let trailingFrames: [SSEFrame]
        if httpError == nil, !leftover.isEmpty, let line = String(data: leftover, encoding: .utf8) {
            trailingFrames = consumeLineLocked(line)
        } else {
            trailingFrames = []
        }
        lock.unlock()
        for frame in trailingFrames { continuation.yield(frame) }
        if let httpError {
            let body = String(data: httpError.body, encoding: .utf8) ?? ""
            continuation.finish(throwing: HermesTransportError.http(status: httpError.status, body: body))
            return
        }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func drainFramesLocked() -> [SSEFrame] {
        var frames: [SSEFrame] = []
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            var rawLine = String(data: lineData, encoding: .utf8) ?? ""
            if rawLine.hasSuffix("\r") { rawLine.removeLast() }
            frames.append(contentsOf: consumeLineLocked(rawLine))
        }
        return frames
    }

    private func consumeLineLocked(_ line: String) -> [SSEFrame] {
        switch SSELineParser.parse(line) {
        case .eventName(let name):
            pendingEvent = name
            return []
        case .dataLine(let chunk):
            pendingData.append(chunk)
            return []
        case .dispatch:
            if pendingData.isEmpty {
                pendingEvent = nil
                return []
            }
            let frame = SSEFrame(event: pendingEvent, data: pendingData.joined(separator: "\n"))
            pendingEvent = nil
            pendingData.removeAll(keepingCapacity: true)
            return [frame]
        case .comment, .unknown:
            return []
        }
    }
}

actor HermesHTTPTransport: NanoTransport {
    private struct ActiveRun {
        let runID: String
        let task: Task<Void, Never>
        let dataTask: URLSessionDataTask
        let delegateSession: URLSession
    }

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private var activeRuns: [String: ActiveRun] = [:]

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    func runTurn(
        channelID: String,
        text: String,
        attachments: [NanoTransportAttachment]
    ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        if let prior = activeRuns.removeValue(forKey: channelID) {
            prior.dataTask.cancel()
            prior.delegateSession.invalidateAndCancel()
            prior.task.cancel()
            _ = await prior.task.value
        }

        let runID = try await startRun(channelID: channelID, text: text, attachments: attachments)

        let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream(bufferingPolicy: .unbounded)

        let (dataTask, delegateSession, frameStream) = makeSSEDataTask(runID: runID)

        let baseURL = self.baseURL
        let apiKey = self.apiKey
        let upstreamSession = self.session

        let task = Task.detached { [weak self] in
            await HermesHTTPTransport.consumeSSEDetached(
                baseURL: baseURL,
                apiKey: apiKey,
                upstreamSession: upstreamSession,
                runID: runID,
                firstAttemptDataTask: dataTask,
                firstAttemptSession: delegateSession,
                firstAttemptFrames: frameStream,
                continuation: continuation,
                retriedOnce: false
            )
            await self?.finalize(channelID: channelID, runID: runID)
        }

        activeRuns[channelID] = ActiveRun(
            runID: runID,
            task: task,
            dataTask: dataTask,
            delegateSession: delegateSession
        )

        continuation.onTermination = { _ in
            dataTask.cancel()
            delegateSession.invalidateAndCancel()
            task.cancel()
        }

        dataTask.resume()

        return stream
    }

    func cancel(channelID: String) async throws {
        let run = activeRuns.removeValue(forKey: channelID)
        if let run {
            run.dataTask.cancel()
            run.delegateSession.invalidateAndCancel()
            run.task.cancel()
            _ = try? await postEmpty(path: "/v1/runs/\(run.runID)/stop")
        }
    }

    func resetSession(channelID: String) async throws {
        _ = try await postJSON(path: "/v1/sessions/reset", body: ["channel_id": channelID])
    }

    func getHistory(
        channelID: String,
        limit: Int,
        afterCursor: Int64?
    ) async throws -> [NanoHistoryMessage] {
        var components = URLComponents(url: baseURL.appendingPathComponent("/v1/sessions/\(channelID)/history"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let afterCursor { items.append(URLQueryItem(name: "after_cursor", value: String(afterCursor))) }
        components.queryItems = items
        let data = try await getRaw(url: components.url!)
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.compactMap { row in
            let id = (row["id"] as? Int64) ?? Int64((row["id"] as? Int) ?? 0)
            let chID = (row["channel_id"] as? String) ?? channelID
            let roleRaw = (row["role"] as? String) ?? "assistant"
            let role: NanoMessageRole = (roleRaw == "user") ? .user : .assistant
            let text = (row["text"] as? String) ?? (row["content"] as? String) ?? ""
            let ts = (row["ts"] as? Int64) ?? Int64((row["ts"] as? Int) ?? 0)
            return NanoHistoryMessage(id: id, channelID: chID, role: role, text: text, ts: ts)
        }
    }

    func listChannels(prefix: String?) async throws -> [NanoChannelInfo] {
        var components = URLComponents(url: baseURL.appendingPathComponent("/v1/channels"), resolvingAgainstBaseURL: false)!
        if let prefix, !prefix.isEmpty {
            components.queryItems = [URLQueryItem(name: "prefix", value: prefix)]
        }
        let data = try await getRaw(url: components.url!)
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.compactMap { row in
            guard let chID = (row["channel_id"] as? String) ?? (row["channelId"] as? String) else { return nil }
            let lastTs = (row["last_ts"] as? Int64) ?? Int64((row["last_ts"] as? Int) ?? 0)
            let msgCount = (row["msg_count"] as? Int) ?? 0
            return NanoChannelInfo(channelID: chID, lastTs: lastTs, msgCount: msgCount)
        }
    }

    private func finalize(channelID: String, runID: String) {
        if let run = activeRuns[channelID], run.runID == runID {
            run.delegateSession.invalidateAndCancel()
            activeRuns.removeValue(forKey: channelID)
        }
    }

    private func makeSSEDataTask(
        runID: String
    ) -> (URLSessionDataTask, URLSession, AsyncThrowingStream<SSEFrame, Error>) {
        let url = baseURL.appendingPathComponent("/v1/runs/\(runID)/events")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (frameStream, frameContinuation) = AsyncThrowingStream<SSEFrame, Error>.makeStream(bufferingPolicy: .unbounded)
        let delegate = SSEDataDelegate(continuation: frameContinuation)
        let config = (session.configuration.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.default
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let delegateSession = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        let dataTask = delegateSession.dataTask(with: request)
        frameContinuation.onTermination = { @Sendable _ in
            dataTask.cancel()
        }
        return (dataTask, delegateSession, frameStream)
    }

    private func startRun(channelID: String, text: String, attachments: [NanoTransportAttachment]) async throws -> String {
        var body: [String: Any] = ["channel_id": channelID, "text": text]
        if !attachments.isEmpty {
            body["attachments"] = attachments.map { a -> [String: Any] in
                var dict: [String: Any] = ["type": a.type, "media_type": a.mediaType, "base64": a.base64]
                if let n = a.name { dict["name"] = n }
                return dict
            }
        }
        let data = try await postJSON(path: "/v1/runs", body: body)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let runID = (obj["id"] as? String) ?? (obj["run_id"] as? String) else {
            throw HermesTransportError.noRunID
        }
        return runID
    }

    private static func consumeSSEDetached(
        baseURL: URL,
        apiKey: String,
        upstreamSession: URLSession,
        runID: String,
        firstAttemptDataTask: URLSessionDataTask,
        firstAttemptSession: URLSession,
        firstAttemptFrames: AsyncThrowingStream<SSEFrame, Error>,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation,
        retriedOnce: Bool
    ) async {
        do {
            for try await frame in firstAttemptFrames {
                if Task.isCancelled { break }
                guard let event = HermesEventMapper.map(frame: frame) else { continue }
                continuation.yield(event)
                if case .done = event {
                    firstAttemptSession.invalidateAndCancel()
                    continuation.finish()
                    return
                }
                if case .failure = event {
                    firstAttemptSession.invalidateAndCancel()
                    continuation.finish()
                    return
                }
            }
            firstAttemptSession.invalidateAndCancel()
            continuation.finish()
        } catch let urlError as URLError where urlError.code == .networkConnectionLost && !retriedOnce {
            hermesLogger.warning("hermes SSE lost; retrying once")
            firstAttemptSession.invalidateAndCancel()
            let url = baseURL.appendingPathComponent("/v1/runs/\(runID)/events")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let (retryStream, retryContinuation) = AsyncThrowingStream<SSEFrame, Error>.makeStream(bufferingPolicy: .unbounded)
            let delegate = SSEDataDelegate(continuation: retryContinuation)
            let config = (upstreamSession.configuration.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.default
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let retrySession = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
            let retryTask = retrySession.dataTask(with: request)
            retryContinuation.onTermination = { @Sendable _ in retryTask.cancel() }
            retryTask.resume()
            await consumeSSEDetached(
                baseURL: baseURL,
                apiKey: apiKey,
                upstreamSession: upstreamSession,
                runID: runID,
                firstAttemptDataTask: retryTask,
                firstAttemptSession: retrySession,
                firstAttemptFrames: retryStream,
                continuation: continuation,
                retriedOnce: true
            )
        } catch is CancellationError {
            firstAttemptSession.invalidateAndCancel()
            continuation.finish()
        } catch let urlError as URLError where urlError.code == .cancelled {
            firstAttemptSession.invalidateAndCancel()
            continuation.finish()
        } catch let hermesError as HermesTransportError {
            firstAttemptSession.invalidateAndCancel()
            if case .http(let status, _) = hermesError {
                continuation.yield(.failure(message: "\(status): hermes events"))
            } else {
                continuation.yield(.failure(message: hermesError.localizedDescription))
            }
            continuation.finish()
        } catch {
            firstAttemptSession.invalidateAndCancel()
            continuation.yield(.failure(message: error.localizedDescription))
            continuation.finish()
        }
    }

    private func applyAuth(_ request: inout URLRequest) {
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        guard let payload = try? JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed]) else {
            throw HermesTransportError.encodeFailed
        }
        request.httpBody = payload
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw HermesTransportError.http(status: http.statusCode, body: msg)
        }
        return data
    }

    private func postEmpty(path: String) async throws -> Data {
        try await postJSON(path: path, body: [:])
    }

    private func getRaw(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(&request)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw HermesTransportError.http(status: http.statusCode, body: msg)
        }
        return data
    }
}
