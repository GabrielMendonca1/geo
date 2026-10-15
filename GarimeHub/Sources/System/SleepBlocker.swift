import Foundation

final class SleepBlocker {
    enum Outcome: Equatable {
        case applied
        case unavailable
        case failed(Int32)
    }

    private(set) var isBlocking = false

    static func arguments(on: Bool) -> [String] {
        ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
    }

    static func isSystemBlocking() -> Bool {
        let output = SleepBlocker.run("/usr/bin/pmset", ["-g"]).text
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled" {
                return parts.count > 1 && parts[1] == "1"
            }
        }
        return false
    }

    var isAvailable: Bool {
        SleepBlocker.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]).code == 0
    }

    @discardableResult
    func apply(_ on: Bool) -> Outcome {
        let result = SleepBlocker.run("/usr/bin/sudo", SleepBlocker.arguments(on: on))
        guard result.code == 0 else {
            isBlocking = false
            return result.text.contains("password") || result.text.contains("sudo:")
                ? .unavailable
                : .failed(result.code)
        }
        isBlocking = on
        return .applied
    }

    func reconcile(wanted: Bool) {
        guard SleepBlocker.isSystemBlocking() != wanted else {
            isBlocking = wanted
            return
        }
        apply(wanted)
    }

    private static func run(_ path: String, _ arguments: [String]) -> (code: Int32, text: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
