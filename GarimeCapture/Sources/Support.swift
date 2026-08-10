import Foundation
import CryptoKit

let fm = FileManager.default
let homeDir = fm.homeDirectoryForCurrentUser

func logErr(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(message)\n".utf8))
}

func envValue(_ key: String) -> String? {
    guard let raw = ProcessInfo.processInfo.environment[key] else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func envInt(_ key: String, _ fallback: Int) -> Int {
    guard let raw = envValue(key), let value = Int(raw), value > 0 else { return fallback }
    return value
}

func envDouble(_ key: String, _ fallback: Double) -> Double {
    guard let raw = envValue(key), let value = Double(raw), value > 0 else { return fallback }
    return value
}

func expandPath(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

let forbiddenRoots: [String] = [
    homeDir.appendingPathComponent("Vault", isDirectory: true).standardizedFileURL.path,
    homeDir.appendingPathComponent("Library/Application Support/Geo", isDirectory: true).standardizedFileURL.path,
]

func isForbiddenPath(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    return forbiddenRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
}

let baseDir: URL = {
    let resolved = envValue("GARIME_CAPTURE_HOME").map(expandPath)
        ?? homeDir
            .appendingPathComponent("Library/Application Support/Garime/GarimeCapture", isDirectory: true)
            .standardizedFileURL
    if isForbiddenPath(resolved) {
        logErr("FATAL: capture home \(resolved.path) resolves inside a forbidden vault root; refusing to run")
        exit(78)
    }
    return resolved
}()

let archiveDir = baseDir.appendingPathComponent("archive", isDirectory: true)
let statusDir = baseDir.appendingPathComponent("status", isDirectory: true)
let registryURL = baseDir.appendingPathComponent("registry", isDirectory: true)
    .appendingPathComponent("processed.json", isDirectory: false)
let legacySpoolDir = baseDir.appendingPathComponent("spool", isDirectory: true)
let failuresURL = registryURL.deletingLastPathComponent()
    .appendingPathComponent("failures.json", isDirectory: false)
let strandedURL = statusDir.appendingPathComponent("stranded", isDirectory: false)

let captureHeartbeat = "capture.heartbeat"
let retentionHeartbeat = "retention.heartbeat"
let retentionStatusURL = statusDir.appendingPathComponent("retention.status", isDirectory: false)

func nowDate() -> Date {
    guard let raw = envValue("GARIME_NOW"), let epoch = Double(raw), epoch > 0 else { return Date() }
    return Date(timeIntervalSince1970: epoch)
}

func beat(_ name: String) {
    try? fm.createDirectory(at: statusDir, withIntermediateDirectories: true)
    let url = statusDir.appendingPathComponent(name, isDirectory: false)
    try? String(Int(Date().timeIntervalSince1970)).write(to: url, atomically: true, encoding: .utf8)
}

func sleepBeating(_ total: TimeInterval, heartbeat: String) {
    var remaining = total
    while remaining > 0 {
        let slice = min(remaining, 15)
        Thread.sleep(forTimeInterval: slice)
        remaining -= slice
        beat(heartbeat)
    }
}

let safeNameScalars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-".unicodeScalars)

func isSafeComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 128 else { return false }
    guard !value.hasPrefix("-"), !value.hasPrefix("."), !value.contains("..") else { return false }
    return value.unicodeScalars.allSatisfy { safeNameScalars.contains($0) }
}

func isArchiveArtifact(_ value: String) -> Bool {
    value.range(
        of: "^[0-9]{8}-[0-9]{6}-[0-9a-f]{10}\\.(png|jpg|jpeg|heic|heif)$",
        options: .regularExpression
    ) != nil
}

func isSafeDayFolder(_ value: String) -> Bool {
    value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
}

func syncToDisk(_ url: URL) -> Bool {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else {
        logErr("fsync: could not open \(url.lastPathComponent) (errno \(errno))")
        return false
    }
    defer { close(fd) }
    if fcntl(fd, F_FULLFSYNC) == 0 { return true }
    if fsync(fd) == 0 { return true }
    logErr("fsync: failed for \(url.lastPathComponent) (errno \(errno))")
    return false
}

func shortDigest(_ chunks: [Data]) -> String {
    var hasher = SHA256()
    for chunk in chunks { hasher.update(data: chunk) }
    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(10))
}
