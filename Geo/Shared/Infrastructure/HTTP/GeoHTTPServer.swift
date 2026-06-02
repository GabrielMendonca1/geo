import Foundation
import Network
import os
import os.log

private let httpLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "GeoHTTPServer")

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
    let requestId: String
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(_ status: Int, _ value: AnyCodableValue, extraHeaders: [String: String] = [:]) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        var headers = ["Content-Type": "application/json; charset=utf-8"]
        for (k, v) in extraHeaders { headers[k] = v }
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    static func error(_ status: Int, _ message: String, extraHeaders: [String: String] = [:]) -> HTTPResponse {
        json(status, .object(["error": .string(message)]), extraHeaders: extraHeaders)
    }

    static func empty(_ status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], body: Data())
    }
}

final class GeoHTTPServer: @unchecked Sendable {
    static let maxConcurrentRequests: Int = 50
    static let maxRequestBytes: Int = 1_048_576

    private let queue = DispatchQueue(label: "geo.http.server", qos: .userInitiated)
    private let router: GeoAPIRouter
    private var listener: NWListener?
    private let inFlightLock = OSAllocatedUnfairLock<Int>(initialState: 0)
    private(set) var port: UInt16 = 0

    init(router: GeoAPIRouter) {
        self.router = router
    }

    var apiInfoURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return appSupport.appendingPathComponent("Geo/api.json")
    }

    func start() throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 60

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.publishAPIInfo(attempt: 0)
            case .failed(let err):
                httpLogger.error("Geo HTTP listener failed: \(err.localizedDescription)")
            case .cancelled:
                httpLogger.info("Geo HTTP listener cancelled")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: apiInfoURL)
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn: conn, buffer: Data())
    }

    private func readRequest(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                httpLogger.debug("conn receive error: \(error.localizedDescription)")
                conn.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }

            if buf.count > Self.maxRequestBytes {
                self.send(.error(413, "request too large"), on: conn, keepAlive: false)
                return
            }

            guard let parsed = HTTPParser.parse(buffer: buf) else {
                if isComplete {
                    conn.cancel()
                    return
                }
                self.readRequest(conn: conn, buffer: buf)
                return
            }

            let (request, leftover) = parsed
            self.dispatch(request: request, on: conn, keepAlive: HTTPParser.shouldKeepAlive(request), pipelinedBuffer: leftover)
        }
    }

    private func dispatch(request: HTTPRequest, on conn: NWConnection, keepAlive: Bool, pipelinedBuffer: Data) {
        let allowed = inFlightLock.withLock { count -> Bool in
            if count >= Self.maxConcurrentRequests { return false }
            count += 1
            return true
        }
        if !allowed {
            send(.error(503, "server busy"), on: conn, keepAlive: false)
            return
        }

        Task { [router, weak self] in
            let started = Date()
            let response = await router.handle(request)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            APIAuditLogger.shared.log(
                callerId: response.headers["X-Geo-Caller"] ?? "anonymous",
                method: request.method,
                path: request.path,
                status: response.status,
                latencyMs: latency,
                requestId: request.requestId
            )
            var clean = response
            clean.headers.removeValue(forKey: "X-Geo-Caller")
            guard let self else { return }
            self.queue.async {
                self.send(clean, on: conn, keepAlive: keepAlive)
                self.inFlightLock.withLock { count in count -= 1 }
                if keepAlive {
                    self.readRequest(conn: conn, buffer: pipelinedBuffer)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on conn: NWConnection, keepAlive: Bool) {
        let statusLine = "HTTP/1.1 \(response.status) \(HTTPParser.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        headers["Server"] = "Geo/1.0"
        var headerStr = statusLine
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
            headerStr += "\(k): \(v)\r\n"
        }
        headerStr += "\r\n"
        var out = Data(headerStr.utf8)
        out.append(response.body)
        conn.send(content: out, completion: .contentProcessed { _ in
            if !keepAlive {
                conn.cancel()
            }
        })
    }

    private func writeAPIInfo(port: UInt16) {
        let url = apiInfoURL
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let payload: [String: AnyCodableValue] = [
            "port": .int(Int(port)),
            "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "version": .string("1.0.0"),
            "started_at": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(payload) else { return }

        let tmp = parent.appendingPathComponent("api.json.tmp.\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            httpLogger.error("api.json write failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

enum HTTPParser {
    static func parse(buffer: Data) -> (HTTPRequest, Data)? {
        guard let headerEnd = findHeaderEnd(buffer) else { return nil }
        let headerData = buffer.prefix(headerEnd)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let method = parts[0]
        let target = parts[1]
        let (path, query) = splitPathQuery(target)

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd + 4
        if buffer.count < bodyStart + contentLength { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        let leftover = buffer.subdata(in: (bodyStart + contentLength)..<buffer.count)

        let request = HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body,
            requestId: UUID().uuidString
        )
        return (request, leftover)
    }

    private static func findHeaderEnd(_ buffer: Data) -> Int? {
        let needle: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard buffer.count >= needle.count else { return nil }
        let bytes = [UInt8](buffer)
        for i in 0...(bytes.count - needle.count) {
            if bytes[i] == needle[0] && bytes[i+1] == needle[1] && bytes[i+2] == needle[2] && bytes[i+3] == needle[3] {
                return i
            }
        }
        return nil
    }

    private static func splitPathQuery(_ target: String) -> (String, [String: String]) {
        guard let qIdx = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<qIdx])
        let qs = String(target[target.index(after: qIdx)...])
        var dict: [String: String] = [:]
        for pair in qs.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                dict[percentDecode(kv[0])] = percentDecode(kv[1])
            } else if kv.count == 1 {
                dict[percentDecode(kv[0])] = ""
            }
        }
        return (path, dict)
    }

    private static func percentDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }

    static func shouldKeepAlive(_ request: HTTPRequest) -> Bool {
        let conn = request.headers["connection"]?.lowercased() ?? "keep-alive"
        return conn != "close"
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}
