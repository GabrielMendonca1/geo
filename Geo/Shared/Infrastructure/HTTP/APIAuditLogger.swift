import Foundation
import os.log

private let auditLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "APIAuditLogger")

final class APIAuditLogger: @unchecked Sendable {
    static let shared = APIAuditLogger()
    static let maxBytes: Int = 10 * 1024 * 1024
    static let maxRotated: Int = 5
    static let sizeCheckInterval: Int = 100

    private let queue = DispatchQueue(label: "geo.http.audit", qos: .utility)
    private var handle: FileHandle?
    private var writesSinceCheck: Int = 0
    private let iso = ISO8601DateFormatter()

    var logURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Geo", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("api-audit.ndjson")
    }

    private func rotatedURL(_ n: Int) -> URL {
        logURL.deletingLastPathComponent().appendingPathComponent("api-audit.\(n).ndjson")
    }

    func log(callerId: String, method: String, path: String, status: Int, latencyMs: Int, requestId: String) {
        queue.async { [weak self] in
            self?.writeLine(callerId: callerId, method: method, path: path, status: status, latencyMs: latencyMs, requestId: requestId)
        }
    }

    private func writeLine(callerId: String, method: String, path: String, status: Int, latencyMs: Int, requestId: String) {
        let entry: [String: AnyCodableValue] = [
            "ts": .string(iso.string(from: Date())),
            "caller_id": .string(callerId),
            "method": .string(method),
            "path": .string(path),
            "status": .int(status),
            "latency_ms": .int(latencyMs),
            "request_id": .string(requestId),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)

        ensureHandleOpen()
        do {
            try handle?.write(contentsOf: data)
        } catch {
            auditLogger.error("audit write failed: \(error.localizedDescription)")
            handle = nil
        }

        writesSinceCheck += 1
        if writesSinceCheck >= Self.sizeCheckInterval {
            writesSinceCheck = 0
            rotateIfNeeded()
        }
    }

    private func ensureHandleOpen() {
        if handle != nil { return }
        let url = logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        do {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            handle = h
        } catch {
            auditLogger.error("audit open failed: \(error.localizedDescription)")
        }
    }

    private func rotateIfNeeded() {
        let url = logURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size >= Self.maxBytes else {
            return
        }
        handle?.closeFile()
        handle = nil

        let fm = FileManager.default
        let oldest = rotatedURL(Self.maxRotated)
        try? fm.removeItem(at: oldest)
        var i = Self.maxRotated - 1
        while i >= 1 {
            let from = rotatedURL(i)
            let to = rotatedURL(i + 1)
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
            i -= 1
        }
        try? fm.moveItem(at: url, to: rotatedURL(1))
        ensureHandleOpen()
    }
}
