import Foundation

enum ClawSignalBusError: Error, LocalizedError {
    case signalsDirectoryUnavailable(underlying: Error)
    case signalWriteFailed(name: String, underlying: Error)
    case bootstrapTokenEncodingFailed
    case bootstrapTokenWriteFailed(underlying: Error)
    case launchAgentInstallScriptUnavailable
    case launchAgentInstallFailed(exitCode: Int32, stderr: String)
    case launchAgentInstallLaunchFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .signalsDirectoryUnavailable(let error):
            return "Couldn't access GeoClaw signals folder: \(error.localizedDescription)"
        case .signalWriteFailed(let name, let error):
            return "Couldn't write signal '\(name)': \(error.localizedDescription)"
        case .bootstrapTokenEncodingFailed:
            return "Bootstrap token isn't valid UTF-8."
        case .bootstrapTokenWriteFailed(let error):
            return "Couldn't write bootstrap token: \(error.localizedDescription)"
        case .launchAgentInstallScriptUnavailable:
            return "Couldn't find the GeoClaw LaunchAgent installer."
        case .launchAgentInstallFailed(let exitCode, let stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return "LaunchAgent installer exited with status \(exitCode)."
            }
            return message
        case .launchAgentInstallLaunchFailed(let error):
            return "Couldn't run LaunchAgent installer: \(error.localizedDescription)"
        }
    }
}

enum ClawSignalBus {
    static let baseFolderName = "GeoClaw"

    private static let cachedURLs: CachedURLs = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = support.appendingPathComponent(baseFolderName, isDirectory: true)
        let signals = base.appendingPathComponent("signals", isDirectory: true)
        let jobs = base.appendingPathComponent("jobs", isDirectory: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CachedURLs(
            base: base,
            signals: signals,
            jobs: jobs,
            status: base.appendingPathComponent("status.json", isDirectory: false),
            qrImage: signals.appendingPathComponent("qr.png", isDirectory: false),
            qrText: signals.appendingPathComponent("qr.txt", isDirectory: false),
            bootstrapToken: signals.appendingPathComponent("bootstrap-token", isDirectory: false),
            telegramToken: signals.appendingPathComponent("telegram-token", isDirectory: false),
            launchAgentPlist: home.appendingPathComponent("Library/LaunchAgents/ai.geo.claw.plist", isDirectory: false)
        )
    }()

    private struct CachedURLs {
        let base: URL
        let signals: URL
        let jobs: URL
        let status: URL
        let qrImage: URL
        let qrText: URL
        let bootstrapToken: URL
        let telegramToken: URL
        let launchAgentPlist: URL
    }

    static func baseDir() -> URL { cachedURLs.base }
    static func signalsDir() -> URL { cachedURLs.signals }
    static func jobsDirURL() -> URL { cachedURLs.jobs }
    static func statusFileURL() -> URL { cachedURLs.status }
    static func qrImageURL() -> URL { cachedURLs.qrImage }
    static func qrTextURL() -> URL { cachedURLs.qrText }
    static func bootstrapTokenURL() -> URL { cachedURLs.bootstrapToken }
    static func telegramTokenURL() -> URL { cachedURLs.telegramToken }
    static func launchAgentPlistURL() -> URL { cachedURLs.launchAgentPlist }

    static func ensureSignalsDir() throws {
        let dir = cachedURLs.signals
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ClawSignalBusError.signalsDirectoryUnavailable(underlying: error)
        }
    }

    static func ensureJobsDir() throws {
        let dir = cachedURLs.jobs
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ClawSignalBusError.signalsDirectoryUnavailable(underlying: error)
        }
    }

    static func writeTelegramToken(_ token: String) throws {
        try ensureSignalsDir()
        guard let data = token.data(using: .utf8) else {
            throw ClawSignalBusError.bootstrapTokenEncodingFailed
        }
        let url = cachedURLs.telegramToken
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func writeSignal(name: String) throws {
        try ensureSignalsDir()
        let url = cachedURLs.signals.appendingPathComponent(name, isDirectory: false)
        if !FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil) {
            throw ClawSignalBusError.signalWriteFailed(
                name: name,
                underlying: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EACCES),
                    userInfo: [NSLocalizedDescriptionKey: "createFile returned false"]
                )
            )
        }
    }

    static func writeBootstrapToken(_ token: String) throws {
        try ensureSignalsDir()
        guard let data = token.data(using: .utf8) else {
            throw ClawSignalBusError.bootstrapTokenEncodingFailed
        }
        let finalURL = cachedURLs.bootstrapToken
        let tmpURL = cachedURLs.signals.appendingPathComponent(
            ".bootstrap-token.\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: tmpURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: finalURL)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw ClawSignalBusError.bootstrapTokenWriteFailed(underlying: error)
        }
    }

    static func isLaunchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: cachedURLs.launchAgentPlist.path)
    }

    static func installLaunchAgent() throws -> ClawLaunchAgentInstallResult {
        guard let script = launchAgentInstallScriptURL() else {
            throw ClawSignalBusError.launchAgentInstallScriptUnavailable
        }
        let result = runShell(at: script)
        guard result.success else {
            throw ClawSignalBusError.launchAgentInstallFailed(
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }

    private static func launchAgentInstallScriptURL() -> URL? {
        let fm = FileManager.default
        let envPath = ProcessInfo.processInfo.environment["GEO_CLAW_INSTALL_SCRIPT"]
        let explicitEnvURL = envPath.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }

        let bundledScript = Bundle.main.url(
            forResource: "install-launchagent",
            withExtension: "sh",
            subdirectory: "geo-claw/scripts"
        ) ?? Bundle.main.url(forResource: "install-launchagent", withExtension: "sh")

        let appSupportScript = cachedURLs.base
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("install-launchagent.sh", isDirectory: false)

        let searchRoots = [
            URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true),
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.deletingLastPathComponent()
        ].compactMap { $0 }

        let discoveredScripts = searchRoots.flatMap { root in
            ancestorDirectories(from: root).flatMap { ancestor in
                [
                    ancestor
                        .appendingPathComponent("geo-claw", isDirectory: true)
                        .appendingPathComponent("scripts", isDirectory: true)
                        .appendingPathComponent("install-launchagent.sh", isDirectory: false),
                    ancestor
                        .appendingPathComponent("scripts", isDirectory: true)
                        .appendingPathComponent("install-launchagent.sh", isDirectory: false)
                ]
            }
        }

        let candidates = [explicitEnvURL, bundledScript, appSupportScript] + discoveredScripts.map(Optional.some)
        return candidates.compactMap { $0 }.first { fm.isExecutableFile(atPath: $0.path) || fm.isReadableFile(atPath: $0.path) }
    }

    private static func ancestorDirectories(from url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        while true {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return result
    }

    private static func runShell(at url: URL) -> ClawLaunchAgentInstallResult {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["bash", url.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            let outRead = asyncRead(outPipe.fileHandleForReading)
            let errRead = asyncRead(errPipe.fileHandleForReading)
            process.waitUntilExit()
            let outData = outRead()
            let errData = errRead()
            return ClawLaunchAgentInstallResult(
                exitCode: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                installed: isLaunchAgentInstalled()
            )
        } catch {
            return ClawLaunchAgentInstallResult(
                exitCode: -1,
                stdout: "",
                stderr: ClawSignalBusError.launchAgentInstallLaunchFailed(underlying: error).localizedDescription,
                installed: isLaunchAgentInstalled()
            )
        }
    }

    private static func asyncRead(_ fileHandle: FileHandle) -> () -> Data {
        let queue = DispatchQueue.global(qos: .utility)
        let group = DispatchGroup()
        var data = Data()
        group.enter()
        queue.async {
            data = fileHandle.readDataToEndOfFile()
            group.leave()
        }
        return {
            group.wait()
            return data
        }
    }
}

struct ClawLaunchAgentInstallResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let installed: Bool

    var success: Bool { exitCode == 0 }
    var combinedOutput: String {
        [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
