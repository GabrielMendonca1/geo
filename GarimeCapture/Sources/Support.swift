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

let spoolDir = baseDir.appendingPathComponent("spool", isDirectory: true)
let statusDir = baseDir.appendingPathComponent("status", isDirectory: true)
let registryURL = baseDir.appendingPathComponent("registry", isDirectory: true)
    .appendingPathComponent("processed.json", isDirectory: false)

let captureHeartbeat = "capture.heartbeat"
let uploadHeartbeat = "upload.heartbeat"
let uploadStatusURL = statusDir.appendingPathComponent("upload.status", isDirectory: false)

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
let safeHostScalars = safeNameScalars.union("@".unicodeScalars)

func isSafeComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 128 else { return false }
    guard !value.hasPrefix("-"), !value.hasPrefix("."), !value.contains("..") else { return false }
    return value.unicodeScalars.allSatisfy { safeNameScalars.contains($0) }
}

func isSpoolArtifact(_ value: String) -> Bool {
    value.range(
        of: "^[0-9]{8}-[0-9]{6}-[0-9a-f]{10}\\.(png|jpg|jpeg|heic|heif|md)$",
        options: .regularExpression
    ) != nil
}

func isSafeDayFolder(_ value: String) -> Bool {
    value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
}

func isSafeRemoteRoot(_ value: String) -> Bool {
    guard value.hasPrefix("/"), !value.hasSuffix("/"), value.count <= 256, !value.contains("..") else { return false }
    let allowed = safeNameScalars.union("/".unicodeScalars)
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
}

func isSafeRemoteHost(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 128, !value.hasPrefix("-") else { return false }
    return value.unicodeScalars.allSatisfy { safeHostScalars.contains($0) }
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

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

struct RunResult {
    let status: Int32
    let timedOut: Bool
    var ok: Bool { !timedOut && status == 0 }
}

func runBounded(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> RunResult {
    guard fm.isExecutableFile(atPath: executable) else {
        logErr("exec missing or not executable: \(executable)")
        return RunResult(status: -1, timedOut: false)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.standardError
    process.standardError = FileHandle.standardError
    do {
        try process.run()
    } catch {
        logErr("exec failed \(executable): \(error.localizedDescription)")
        return RunResult(status: -1, timedOut: false)
    }

    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        logErr("timeout after \(Int(timeout))s, killing: \(executable)")
        process.terminate()
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = semaphore.wait(timeout: .now() + 5)
        }
        return RunResult(status: -1, timedOut: true)
    }
    return RunResult(status: process.terminationStatus, timedOut: false)
}
