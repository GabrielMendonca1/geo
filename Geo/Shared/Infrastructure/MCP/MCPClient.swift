import Foundation
import os.log

private let mcpClientLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "MCPClient")

enum MCPClientError: Error, LocalizedError {
    case spawnFailed(String)
    case notConnected
    case encodeFailed(Error)
    case decodeFailed(Error)
    case toolError(String)
    case toolErrorWithStderr(String, String)
    case timeout
    case concurrencyExceeded

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let m): return "Failed to spawn MCP child: \(m)"
        case .notConnected: return "MCP child not connected"
        case .encodeFailed(let e): return "MCP encode failed: \(e.localizedDescription)"
        case .decodeFailed(let e): return "MCP decode failed: \(e.localizedDescription)"
        case .toolError(let m): return "MCP tool error: \(m)"
        case .toolErrorWithStderr(let m, let stderr):
            if stderr.isEmpty { return "MCP tool error: \(m)" }
            return "MCP tool error: \(m)\n--- child stderr (tail) ---\n\(stderr)"
        case .timeout: return "MCP request timed out"
        case .concurrencyExceeded: return "MCP in-flight cap reached"
        }
    }
}

enum MCPEvent: Sendable {
    case progress(String)
    case partial(AnyCodableValue)
    case result(AnyCodableValue)
    case error(String)
}

struct MCPServerSpec: Sendable {
    let name: String
    let command: String
    let arguments: [String]
    let environment: [String: String]?

    init(name: String, command: String, arguments: [String] = [], environment: [String: String]? = nil) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }
}

// Caller must invoke `await MCPClient.shared.shutdownAll()` on app termination
// (e.g. in AppDelegate.applicationWillTerminate) to send SIGTERM to spawned
// child processes. `deinit` also terminates surviving children, but actors are
// rarely deallocated before process exit so the explicit shutdown is the
// reliable path.
actor MCPClient {
    static let shared = MCPClient(maxInFlight: 4)

    private let maxInFlight: Int
    private let defaultTimeout: Duration
    private var children: [String: ChildHandle] = [:]
    private var nextID: Int = 1
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Async semaphore: callers wait for an in-flight slot instead of failing fast.
    private var availableSlots: Int
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    private struct PendingRequest {
        let continuation: AsyncThrowingStream<MCPEvent, Error>.Continuation
        let childName: String
    }
    private var pending: [Int: PendingRequest] = [:]

    private final class StderrBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private let cap: Int
        init(cap: Int = 64 * 1024) { self.cap = cap }
        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            bytes.append(data)
            if bytes.count > cap {
                bytes.removeFirst(bytes.count - cap)
            }
        }
        func snapshot() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(data: bytes, encoding: .utf8) ?? ""
        }
    }

    private final class StdoutBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        func append(_ chunk: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            pending += chunk
            guard pending.contains("\n") else { return [] }
            let parts = pending.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            pending = parts.last ?? ""
            return parts.dropLast().filter { !$0.isEmpty }
        }
        func flush() -> [String] {
            lock.lock(); defer { lock.unlock() }
            defer { pending = "" }
            return pending.isEmpty ? [] : [pending]
        }
    }

    private final class ChildHandle {
        let name: String
        let process: Process
        let stdin: FileHandle
        let stderrBuffer: StderrBuffer
        var readerTask: Task<Void, Never>?
        init(name: String, process: Process, stdin: FileHandle, stderrBuffer: StderrBuffer) {
            self.name = name
            self.process = process
            self.stdin = stdin
            self.stderrBuffer = stderrBuffer
        }
    }

    init(maxInFlight: Int = 4, defaultTimeout: Duration = .seconds(60)) {
        self.maxInFlight = max(maxInFlight, 1)
        self.availableSlots = max(maxInFlight, 1)
        self.defaultTimeout = defaultTimeout
    }

    deinit {
        // Best-effort: actors usually outlive the process, but if this client is
        // released we still want to kill the children so they don't orphan.
        for (_, child) in children where child.process.isRunning {
            child.process.terminate()
        }
    }

    // MARK: - Slot semaphore

    private func acquireSlot() async {
        if availableSlots > 0 {
            availableSlots -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            slotWaiters.append(cont)
        }
    }

    private func releaseSlot() {
        if !slotWaiters.isEmpty {
            let next = slotWaiters.removeFirst()
            next.resume()
        } else {
            availableSlots = min(availableSlots + 1, maxInFlight)
        }
    }

    // MARK: - Child lifecycle

    private func ensureChild(spec: MCPServerSpec) throws -> ChildHandle {
        if let existing = children[spec.name], existing.process.isRunning {
            return existing
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let cmd = ([spec.command] + spec.arguments).map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
        process.arguments = ["-lc", cmd]
        if let env = spec.environment { process.environment = env }
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let stderrBuffer = StderrBuffer()
        let stdoutBuffer = StdoutBuffer()
        let handle = ChildHandle(name: spec.name, process: process, stdin: inPipe.fileHandleForWriting, stderrBuffer: stderrBuffer)

        let childName = spec.name
        let stderrCategory = "MCPClient.\(childName)"
        let stderrLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: stderrCategory)

        // Stderr drain: buffer last 64KB + log every chunk.
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            stderrBuffer.append(data)
            if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                stderrLogger.debug("\(line, privacy: .public)")
            }
        }

        // Stdout pump → AsyncStream of complete lines.
        let (rawStream, rawContinuation) = AsyncStream<String>.makeStream(of: String.self)
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            for line in stdoutBuffer.append(chunk) { rawContinuation.yield(line) }
        }

        process.terminationHandler = { _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            for line in stdoutBuffer.flush() { rawContinuation.yield(line) }
            rawContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            throw MCPClientError.spawnFailed(error.localizedDescription)
        }

        // Single long-lived router task: read every line, dispatch by id.
        handle.readerTask = Task { [weak self] in
            for await line in rawStream {
                await self?.routeLine(line, childName: childName)
            }
            await self?.handleChildEOF(childName: childName)
        }

        children[spec.name] = handle
        return handle
    }

    private func routeLine(_ raw: String, childName: String) {
        guard let bytes = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            return
        }

        // Notification (no id). Per JSON-RPC, broadcast to every active caller
        // routed through this child. notifications/progress carries a
        // human-readable string; other notifications surface as `.partial`.
        if obj["id"] == nil {
            if let method = obj["method"] as? String, method == "notifications/progress" {
                let token = (obj["params"] as? [String: Any]).flatMap { $0["message"] as? String } ?? "progress"
                for (_, req) in pending where req.childName == childName {
                    req.continuation.yield(.progress(token))
                }
                return
            }
            if let params = obj["params"] {
                let pData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
                if let value = try? decoder.decode(AnyCodableValue.self, from: pData) {
                    for (_, req) in pending where req.childName == childName {
                        req.continuation.yield(.partial(value))
                    }
                }
            }
            return
        }

        guard let id = obj["id"] as? Int, let req = pending[id] else {
            // Either we got a response for an id we don't track (timed out and
            // cleaned up) or the response shape is unexpected. Either way:
            // drop it silently.
            return
        }

        if let errObj = obj["error"] as? [String: Any] {
            let msg = (errObj["message"] as? String) ?? "unknown error"
            req.continuation.yield(.error(msg))
            req.continuation.finish()
            pending.removeValue(forKey: id)
            return
        }

        if let result = obj["result"] {
            let resData = (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
            if let value = try? decoder.decode(AnyCodableValue.self, from: resData) {
                req.continuation.yield(.result(value))
            }
            req.continuation.finish()
            pending.removeValue(forKey: id)
            return
        }
    }

    private func handleChildEOF(childName: String) {
        // The child closed stdout. Any callers still waiting on it will never
        // see a response → fail them with notConnected and surface stderr.
        let stderrTail = children[childName]?.stderrBuffer.snapshot() ?? ""
        let ids = pending.compactMap { (k, v) -> Int? in v.childName == childName ? k : nil }
        for id in ids {
            let req = pending.removeValue(forKey: id)
            req?.continuation.finish(throwing: MCPClientError.toolErrorWithStderr("MCP child '\(childName)' exited", stderrTail))
        }
    }

    private func unregister(id: Int) {
        pending.removeValue(forKey: id)
    }

    // MARK: - Public API

    func callTool(
        spec: MCPServerSpec,
        name: String,
        input: AnyCodableValue
    ) -> AsyncThrowingStream<MCPEvent, Error> {
        AsyncThrowingStream<MCPEvent, Error> { continuation in
            Task {
                do {
                    try await self.runCall(spec: spec, toolName: name, input: input, sink: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func runCall(
        spec: MCPServerSpec,
        toolName: String,
        input: AnyCodableValue,
        sink: AsyncThrowingStream<MCPEvent, Error>.Continuation
    ) async throws {
        await acquireSlot()
        var slotReleased = false
        func releaseOnce() {
            if !slotReleased {
                slotReleased = true
                releaseSlot()
            }
        }
        defer { releaseOnce() }

        let child = try ensureChild(spec: spec)
        let requestID = nextID; nextID += 1

        let args: AnyCodableValue
        if case .object = input { args = input } else { args = .object([:]) }
        let payload: [String: AnyCodableValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(requestID),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string(toolName),
                "arguments": args
            ])
        ]

        // Internal sink: events from router land here. We pipe them to the
        // caller's sink so we can intercept terminal events and unblock the
        // timeout.
        let (routedStream, routedContinuation) = AsyncThrowingStream<MCPEvent, Error>.makeStream()
        pending[requestID] = PendingRequest(continuation: routedContinuation, childName: spec.name)

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            unregister(id: requestID)
            routedContinuation.finish()
            throw MCPClientError.encodeFailed(error)
        }
        var line = data
        line.append(0x0a)
        do {
            try child.stdin.write(contentsOf: line)
        } catch {
            unregister(id: requestID)
            routedContinuation.finish()
            let stderr = child.stderrBuffer.snapshot()
            throw MCPClientError.toolErrorWithStderr("write to child failed: \(error.localizedDescription)", stderr)
        }

        let timeoutNanos = UInt64(defaultTimeout.components.seconds) * 1_000_000_000
            + UInt64(defaultTimeout.components.attoseconds / 1_000_000_000)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanos)
            if Task.isCancelled { return }
            await self?.fireTimeout(id: requestID)
        }

        defer { timeoutTask.cancel() }

        do {
            for try await event in routedStream {
                sink.yield(event)
                if case .result = event { sink.finish(); return }
                if case .error = event { sink.finish(); return }
            }
            sink.finish()
        } catch {
            // Router or timeout closed the routed stream with an error. If
            // it's a timeout, augment with stderr tail.
            if case MCPClientError.timeout = error {
                let stderr = child.stderrBuffer.snapshot()
                if stderr.isEmpty {
                    throw MCPClientError.timeout
                }
                throw MCPClientError.toolErrorWithStderr("timeout", stderr)
            }
            throw error
        }
    }

    private func fireTimeout(id: Int) {
        guard let req = pending.removeValue(forKey: id) else { return }
        req.continuation.finish(throwing: MCPClientError.timeout)
    }

    func shutdown(name: String) {
        guard let child = children.removeValue(forKey: name) else { return }
        child.readerTask?.cancel()
        if child.process.isRunning { child.process.terminate() }
        let stderrTail = child.stderrBuffer.snapshot()
        let ids = pending.compactMap { (k, v) -> Int? in v.childName == name ? k : nil }
        for id in ids {
            let req = pending.removeValue(forKey: id)
            req?.continuation.finish(throwing: MCPClientError.toolErrorWithStderr("MCP child '\(name)' shut down", stderrTail))
        }
    }

    func shutdownAll() {
        let names = Array(children.keys)
        for name in names { shutdown(name: name) }
    }
}
