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

    init(runtimeLookup: ((String) -> JobRuntime?)? = nil) {
        _ = runtimeLookup
    }

    func refresh() {
        Task { [weak self] in
            await self?.runRefresh()
        }
    }

    func add(_ spec: JobSpec) throws {
        let input: AnyCodableValue = .object([
            "id": .string(spec.id),
            "title": .string(spec.title),
            "name": .string(spec.id),
            "schedule": .string(spec.cron),
            "cron": .string(spec.cron),
            "prompt": .string(spec.prompt),
        ])
        Task { [weak self] in
            await self?.runMutation(toolName: "mcp_hermes_cron_add", input: input, op: "add")
        }
    }

    func remove(_ id: String) throws {
        Task { [weak self] in
            await self?.runMutation(
                toolName: "mcp_hermes_cron_remove",
                input: .object(["id": .string(id)]),
                op: "remove"
            )
        }
    }

    private func runRefresh() async {
        let stream = await MCPClient.shared.callTool(
            spec: HermesStatusService.hermesServerSpec(),
            name: "mcp_hermes_cron_list",
            input: .object([:])
        )
        do {
            let result = try await Self.collectResult(stream: stream)
            let parsed = Self.parseJobs(from: result)
            self.jobs = parsed
            self.lastError = nil
        } catch {
            jobStoreLogger.warning("JobStore.refresh failed: \(error.localizedDescription, privacy: .public)")
            self.jobs = []
            self.lastError = "Couldn't reach hermes cron: \(error.localizedDescription)"
        }
    }

    private func runMutation(toolName: String, input: AnyCodableValue, op: String) async {
        let stream = await MCPClient.shared.callTool(
            spec: HermesStatusService.hermesServerSpec(),
            name: toolName,
            input: input
        )
        do {
            _ = try await Self.collectResult(stream: stream)
            self.lastError = nil
            await runRefresh()
        } catch {
            jobStoreLogger.warning("JobStore.\(op, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = "hermes cron \(op) failed: \(error.localizedDescription)"
        }
    }

    private static func collectResult(stream: AsyncThrowingStream<MCPEvent, Error>) async throws -> AnyCodableValue {
        for try await event in stream {
            switch event {
            case .result(let value): return value
            case .error(let message): throw MCPClientError.toolError(message)
            default: continue
            }
        }
        return .null
    }

    private static func parseJobs(from value: AnyCodableValue) -> [Job] {
        let arr = arrayPayload(from: value)
        var out: [Job] = []
        for entry in arr {
            guard case .object(let obj) = entry else { continue }
            let id = obj["id"]?.stringValue ?? obj["name"]?.stringValue ?? UUID().uuidString
            let title = obj["title"]?.stringValue ?? obj["name"]?.stringValue ?? id
            let cron = obj["schedule"]?.stringValue ?? obj["cron"]?.stringValue ?? ""
            let prompt = obj["prompt"]?.stringValue ?? ""
            let spec = JobSpec(id: id, title: title, cron: cron, prompt: prompt, sinks: [])
            let runtime = parseRuntime(id: id, from: obj)
            out.append(Job(spec: spec, runtime: runtime))
        }
        return out
    }

    private static func arrayPayload(from value: AnyCodableValue) -> [AnyCodableValue] {
        if case .array(let a) = value { return a }
        if case .object(let obj) = value {
            if let arr = obj["crons"]?.arrayValue { return arr }
            if let arr = obj["jobs"]?.arrayValue { return arr }
            if let arr = obj["items"]?.arrayValue { return arr }
            if let content = obj["content"]?.arrayValue {
                for c in content {
                    if case .object(let cobj) = c, let text = cobj["text"]?.stringValue,
                       let data = text.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode(AnyCodableValue.self, from: data) {
                        return arrayPayload(from: decoded)
                    }
                }
            }
        }
        return []
    }

    private static func parseRuntime(id: String, from obj: [String: AnyCodableValue]) -> JobRuntime? {
        let status = obj["last_status"]?.stringValue ?? obj["status"]?.stringValue ?? ""
        let error = obj["last_error"]?.stringValue ?? obj["error"]?.stringValue
        var lastRun: Date?
        if let ms = obj["last_run_ms"]?.doubleValue {
            lastRun = Date(timeIntervalSince1970: ms / 1000)
        } else if let s = obj["last_run"]?.stringValue {
            lastRun = ISO8601DateFormatter().date(from: s)
        }
        if status.isEmpty && lastRun == nil && error == nil { return nil }
        return JobRuntime(id: id, lastRun: lastRun, lastStatus: status, error: error)
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
