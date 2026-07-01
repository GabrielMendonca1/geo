import Foundation
import SwiftUI
import os

private let jobStoreLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "JobStore")

struct JobSpec: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let cron: String
    let prompt: String
    let sinks: [String]
}

struct Job: Identifiable, Equatable {
    let spec: JobSpec
    let runtime: JobRuntime?
    var id: String { spec.id }
}

struct JobRuntime: Equatable, Identifiable {
    let id: String
    let lastRun: Date?
    let lastStatus: String
    let error: String?
}

@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var lastError: String?

    private lazy var poller = Poller(interval: 5_000_000_000) { [weak self] in
        await self?.runRefresh()
    }

    func refresh() {
        Task { [weak self] in
            await self?.runRefresh()
        }
    }

    func startPolling() {
        poller.start()
    }

    func stopPolling() {
        poller.stop()
    }

    func add(_ spec: JobSpec) {
        Task { [weak self] in
            await self?.runHermesCron(args: [
                "cron", "create",
                spec.cron,
                spec.prompt,
                "--name", spec.title,
            ], op: "add")
        }
    }

    func remove(_ id: String) {
        Task { [weak self] in
            await self?.runHermesCron(args: ["cron", "remove", id], op: "remove")
        }
    }

    private func runRefresh() async {
        let parsed = await Self.readStatus()
        switch parsed {
        case .success(let list):
            self.jobs = list
            self.lastError = nil
        case .failure(let err):
            jobStoreLogger.warning("JobStore.refresh failed: \(err.localizedDescription, privacy: .public)")
            self.jobs = []
            self.lastError = err.localizedDescription
        }
    }

    private func runHermesCron(args: [String], op: String) async {
        let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            let proc = Process()
            proc.launchPath = "/bin/zsh"
            proc.arguments = ["-lc", (["hermes"] + args).map { Self.shellQuote($0) }.joined(separator: " ")]
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderr = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (proc.terminationStatus, stderr)
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value

        if result.0 == 0 {
            self.lastError = nil
            await runRefresh()
        } else {
            let detail = result.1.isEmpty ? "exit \(result.0)" : result.1
            jobStoreLogger.warning("JobStore.\(op, privacy: .public) failed: \(detail, privacy: .public)")
            self.lastError = "hermes cron \(op) failed: \(detail)"
        }
    }

    private nonisolated static func shellQuote(_ s: String) -> String {
        guard !s.isEmpty else { return "''" }
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_/.=:@,".contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func readStatus() async -> Result<[Job], Error> {
        let status = await HermesStatus.read()
        let arr = status?.crons ?? []
        let jobs: [Job] = arr.compactMap { Self.parseJob($0) }
        return .success(jobs)
    }

    private nonisolated static func parseJob(_ obj: HermesStatus.Cron) -> Job? {
        let id = obj.id ?? ""
        guard !id.isEmpty else { return nil }
        let title = obj.title ?? id
        let schedule = obj.schedule ?? ""
        let prompt = obj.prompt ?? ""
        let spec = JobSpec(id: id, title: title, cron: schedule, prompt: prompt, sinks: [])
        var lastRun: Date?
        if let s = obj.last_run_at {
            lastRun = ISO8601DateFormatter().date(from: s)
        }
        let lastStatus = obj.last_status ?? ""
        let lastError = obj.last_error
        let runtime: JobRuntime?
        if lastRun != nil || !lastStatus.isEmpty || lastError != nil {
            runtime = JobRuntime(id: id, lastRun: lastRun, lastStatus: lastStatus, error: lastError)
        } else {
            runtime = nil
        }
        return Job(spec: spec, runtime: runtime)
    }
}

enum JobSlug {
    static func make(_ raw: String) -> String {
        let lower = raw.lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in lower.unicodeScalars {
            let isAlnum = CharacterSet.alphanumerics.contains(scalar)
            if isAlnum {
                result.append(Character(scalar))
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        if result.isEmpty { result = "job" }
        return result
    }

    static func jobID(from title: String) -> String {
        "\(make(title))-\(Int(Date().timeIntervalSince1970))"
    }
}
