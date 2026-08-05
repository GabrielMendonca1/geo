import Foundation
import GeoCore

enum BridgeError: LocalizedError {
    case unreachable(String)
    case unauthorized
    case server(status: Int, code: String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            return "Bridge unreachable: \(detail)"
        case .unauthorized:
            return "Unauthorized — check the bridge token in Settings"
        case .server(let status, let code):
            return code.isEmpty ? "Bridge error (\(status))" : "Bridge error (\(status)): \(code)"
        case .unsupported(let operation):
            return "\(operation) is not supported over the bridge in v1"
        }
    }
}

struct SSEMessage: Sendable {
    let event: String
    let data: String
}

protocol BridgeAPI: Sendable {
    func getData(_ path: String, token: String?) async throws -> Data
    func postData(_ path: String, body: Data?, token: String?) async throws -> Data
    func delete(_ path: String, token: String?) async throws -> Data
    func uploadFile(_ path: String, body: Data, filename: String, token: String?) async throws -> Data
    func get<T: Decodable>(_ path: String, decoder: JSONDecoder) async throws -> T
    func post<T: Decodable>(_ path: String, body: Data?, decoder: JSONDecoder) async throws -> T
    func stream(
        _ path: String,
        method: String,
        body: Data?,
        token: String?
    ) -> AsyncThrowingStream<SSEMessage, Error>
    func health() async throws
}

extension BridgeAPI {
    func getData(_ path: String) async throws -> Data {
        try await getData(path, token: nil)
    }

    func postData(_ path: String, body: Data? = nil) async throws -> Data {
        try await postData(path, body: body, token: nil)
    }

    func delete(_ path: String) async throws -> Data {
        try await delete(path, token: nil)
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await get(path, decoder: JSONDecoder())
    }

    func post<T: Decodable>(_ path: String, body: Data? = nil) async throws -> T {
        try await post(path, body: body, decoder: JSONDecoder())
    }

    func post<T: Decodable>(_ path: String, decoder: JSONDecoder) async throws -> T {
        try await post(path, body: nil, decoder: decoder)
    }
}

struct BridgeClient: BridgeAPI, Sendable {
    static let shared = BridgeClient()

    let requestTimeout: TimeInterval
    let streamTimeout: TimeInterval

    init(requestTimeout: TimeInterval = 10, streamTimeout: TimeInterval = 90) {
        self.requestTimeout = requestTimeout
        self.streamTimeout = streamTimeout
    }

    static let iso8601Decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = LenientDate.decodingStrategy
        return decoder
    }()

    static let iso8601Encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func health() async throws {
        _ = try await send(path: BridgeEndpoint.health.path, method: "GET", authorized: false)
    }

    func getData(_ path: String, token: String? = nil) async throws -> Data {
        try await send(path: path, method: "GET", token: token)
    }

    func postData(_ path: String, body: Data? = nil, token: String? = nil) async throws -> Data {
        try await send(path: path, method: "POST", body: body, token: token)
    }

    @discardableResult
    func delete(_ path: String, token: String? = nil) async throws -> Data {
        try await send(path: path, method: "DELETE", token: token)
    }

    func uploadFile(_ path: String, body: Data, filename: String, token: String? = nil) async throws -> Data {
        var request = try makeRequest(path: path, method: "POST", authorized: true, token: token)
        request.timeoutInterval = streamTimeout
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(filename, forHTTPHeaderField: "X-Geo-Filename")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data: data)
            return data
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError.unreachable(error.localizedDescription)
        }
    }

    func get<T: Decodable>(_ path: String, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        try decoder.decode(T.self, from: try await getData(path))
    }

    func post<T: Decodable>(_ path: String, body: Data? = nil, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        try decoder.decode(T.self, from: try await postData(path, body: body))
    }

    func stream(_ path: String, method: String = "GET", body: Data? = nil, token: String? = nil) -> AsyncThrowingStream<SSEMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest(path: path, method: method, authorized: true, token: token)
                    request.timeoutInterval = streamTimeout
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let body {
                        request.httpBody = body
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes.prefix(2048) { body.append(byte) }
                        try Self.check(response, data: body)
                    }
                    var pendingEvent: String?
                    for try await line in bytes.lines {
                        if line.hasPrefix(":") { continue }
                        if line.hasPrefix("event:") {
                            var name = String(line.dropFirst(6))
                            if name.hasPrefix(" ") { name.removeFirst() }
                            pendingEvent = name
                        } else if line.hasPrefix("data:") {
                            var payload = String(line.dropFirst(5))
                            if payload.hasPrefix(" ") { payload.removeFirst() }
                            continuation.yield(SSEMessage(event: pendingEvent ?? "message", data: payload))
                            pendingEvent = nil
                        }
                    }
                    continuation.finish()
                } catch let error as BridgeError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: BridgeError.unreachable(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func send(path: String, method: String, body: Data? = nil, authorized: Bool = true, token: String? = nil) async throws -> Data {
        var request = try makeRequest(path: path, method: method, authorized: authorized, token: token)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data: data)
            return data
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError.unreachable(error.localizedDescription)
        }
    }

    private func makeRequest(path: String, method: String, authorized: Bool, token: String? = nil) throws -> URLRequest {
        guard let url = URL(string: BridgeConfig.baseURLString + path) else {
            throw BridgeError.unreachable("invalid bridge URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        if authorized {
            request.setValue("Bearer \(token ?? BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func check(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if (200..<300).contains(http.statusCode) { return }
        if http.statusCode == 401 { throw BridgeError.unauthorized }
        var code = ""
        if let data,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let value = object["error"] {
            code = value
        }
        throw BridgeError.server(status: http.statusCode, code: code)
    }
}
