import Foundation

// MARK: - In-app ingest (delegates to the brain.py CLI → Claude Code account, no API key)

enum VaultIngestError: LocalizedError {
    case cliMissing
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .cliMissing: return "brain.py isn't bundled. Set the UserDefaults key 'BrainCLIPath' to the script path."
        case .failed(let message): return message.isEmpty ? "Ingest failed." : message
        }
    }
}

enum VaultIngest {
    @discardableResult
    static func ingest(folder: URL, sources: [String] = []) async throws -> Int {
        guard let script = scriptURL() else { throw VaultIngestError.cliMissing }
        let before = BrainVaultStore.noteFiles(in: folder).count
        let process = Process()
        // Pin to the system interpreter (3.9.6) — `env python3` can resolve to a brew 3.x
        // with different behavior; the stdlib-only script needs nothing else.
        let pinned = "/usr/bin/python3"
        let usePinned = FileManager.default.isExecutableFile(atPath: pinned)
        process.executableURL = URL(fileURLWithPath: usePinned ? pinned : "/usr/bin/env")
        var args: [String] = usePinned ? [] : ["python3"]
        args += [script.path, "ingest", folder.lastPathComponent] + sources
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GEO_BRAINS_ROOT"] = folder.deletingLastPathComponent().path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in cont.resume() }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw VaultIngestError.failed(output.split(separator: "\n").last.map(String.init) ?? output)
        }
        return max(0, BrainVaultStore.noteFiles(in: folder).count - before)
    }

    static func rebuildIndex(in folder: URL, title: String, gist: String) {
        let notes = BrainVaultStore.noteFiles(in: folder).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines = ["# \(title)", ""]
        if !gist.isEmpty { lines += [gist, ""] }
        lines += ["## Notes (\(notes.count))", ""] + notes.map { "- [[\($0.deletingPathExtension().lastPathComponent)]]" }
        try? (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        if var meta = BrainVaultStore.meta(in: folder) {
            meta.nodes = notes.count
            meta.sources = BrainVaultStore.sourceFiles(in: folder).map { $0.lastPathComponent }
            meta.updated = ISO8601DateFormatter().string(from: Date())
            try? BrainVaultStore.writeMeta(meta, to: folder)
        }
    }

    private static func scriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "brain", withExtension: "py") { return bundled }
        if let override = UserDefaults.standard.string(forKey: "BrainCLIPath"), FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        return nil
    }
}
