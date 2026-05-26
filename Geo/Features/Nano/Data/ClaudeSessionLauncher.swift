import Foundation
import AppKit

enum ClaudeSessionLauncher {
    enum LaunchError: LocalizedError {
        case ghosttyNotFound
        case tuiNotBuilt
        case wrapperWriteFailed(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .ghosttyNotFound: return "Ghostty.app not found in /Applications"
            case .tuiNotBuilt: return "geo-claw TUI not built. Run `npm run build` inside geo-claw."
            case .wrapperWriteFailed(let m): return "Failed to write launcher script: \(m)"
            case .launchFailed(let m): return "Failed to launch Ghostty: \(m)"
            }
        }
    }

    private static let ghosttyAppURL = URL(fileURLWithPath: "/Applications/Ghostty.app")
    private static let tuiEntryPath = "/Users/biel/ARC/Forge/Geo/geo-claw/dist/tuiBoot.js"
    private static let logPath = "/tmp/geo-launch.log"

    static func open() throws {
        guard FileManager.default.fileExists(atPath: ghosttyAppURL.path) else {
            throw LaunchError.ghosttyNotFound
        }
        guard FileManager.default.fileExists(atPath: tuiEntryPath) else {
            throw LaunchError.tuiNotBuilt
        }
        let body = """
        LOG=/tmp/geo-tui-debug.log
        echo "[$(date)] tui.sh started" >> $LOG
        echo "  pid=$$" >> $LOG
        echo "  tty=$(tty 2>&1)" >> $LOG
        echo "  PATH=$PATH" >> $LOG
        echo "  node=$(command -v node 2>&1)" >> $LOG
        export GEO_CLAW_PROVIDER=claude
        if ! command -v node >/dev/null 2>&1; then
          echo "[$(date)] node not found, aborting" >> $LOG
          echo "node not found in PATH"
          echo "PATH=$PATH"
          echo
          echo "press enter to close"
          read
          exit 1
        fi
        echo "[$(date)] exec node \(tuiEntryPath)" >> $LOG
        exec node \(tuiEntryPath)
        """
        let script = try writeWrapper(name: "tui", body: body)
        try launchGhostty(scriptPath: script.path)
    }

    private static func writeWrapper(name: String, body: String) throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("Geo/launchers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(name).sh")
            let content = "#!/bin/zsh -il\n\(body)\n"
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: url.path)
            return url
        } catch {
            throw LaunchError.wrapperWriteFailed(error.localizedDescription)
        }
    }

    private static func appendLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(stamp)] \(line)\n"
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath),
               let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    private static func launchGhostty(scriptPath: String) throws {
        appendLog("launchGhostty start (AppleScript)")
        appendLog("  scriptPath: \(scriptPath)")
        appendLog("  scriptExists: \(FileManager.default.fileExists(atPath: scriptPath))")

        let escaped = scriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
        tell application "Ghostty"
          activate
          set cfg to new surface configuration
          set command of cfg to "\(escaped)"
          set wait after command of cfg to true
          new window with configuration cfg
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            appendLog("  failed to compile AppleScript")
            throw LaunchError.launchFailed("Failed to compile AppleScript")
        }

        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)

        if let err = error {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "unknown"
            let num = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            appendLog("  threw: [\(num)] \(msg)")
            throw LaunchError.launchFailed("AppleScript [\(num)]: \(msg)")
        }
        appendLog("  ok")
    }
}
