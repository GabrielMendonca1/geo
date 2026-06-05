import Combine
import Foundation

@MainActor
final class HermesKanbanService: ObservableObject {
    struct KanbanTask: Identifiable, Equatable {
        let id: String
        let title: String
        let assignee: String?
        let status: String
        let workspaceKind: String
        let workspacePath: String?
        let priority: Int
        let createdAt: Date
        let startedAt: Date?
        let completedAt: Date?
        let result: String?
        let lastEventKind: String?
        let lastEventAt: Date?
    }

    @Published private(set) var tasks: [KanbanTask] = []
    @Published private(set) var lastError: String?
    @Published private(set) var dbAvailable: Bool = false

    private static let registryURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".hermes/dispatches")

    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        dbAvailable = false
    }

    private func tick() async {
        let root = Self.registryURL
        let (available, mapped) = await Task.detached(priority: .utility) {
            Self.scan(root: root)
        }.value
        if dbAvailable != available { dbAvailable = available }
        if mapped != tasks { tasks = mapped }
        if lastError != nil { lastError = nil }
    }

    private nonisolated static func scan(root: URL) -> (Bool, [KanbanTask]) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return (false, [])
        }
        let tasks = dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { task(in: $0) }
            .sorted { lhs, rhs in
                if lhs.status == "running", rhs.status != "running" { return true }
                if rhs.status == "running", lhs.status != "running" { return false }
                return (lhs.startedAt ?? lhs.createdAt) > (rhs.startedAt ?? rhs.createdAt)
            }
        return (true, Array(tasks.prefix(80)))
    }

    private struct Meta: Decodable {
        let id: String?
        let title: String?
        let dir: String?
        let started_at: Double?
    }

    private static func task(in dir: URL) -> KanbanTask? {
        guard let metaData = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: metaData)
        else { return nil }

        let rawStatus = readTrimmed(dir.appendingPathComponent("status")) ?? "running"
        // The CLI writes running|done|failed; reuse the existing UI's "blocked" icon for failures.
        let status = rawStatus == "failed" ? "blocked" : rawStatus

        let started = meta.started_at.map { Date(timeIntervalSince1970: $0) }
        let ended = readTrimmed(dir.appendingPathComponent("ended_at"))
            .flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }

        var result: String?
        if status != "running",
           let rData = try? Data(contentsOf: dir.appendingPathComponent("result.json")),
           let obj = try? JSONSerialization.jsonObject(with: rData) as? [String: Any] {
            result = (obj["result"] as? String) ?? (obj["error"] as? String)
        }

        return KanbanTask(
            id: meta.id ?? dir.lastPathComponent,
            title: meta.title ?? dir.lastPathComponent,
            assignee: "claude-code",
            status: status,
            workspaceKind: "dir",
            workspacePath: meta.dir,
            priority: 0,
            createdAt: started ?? Date(timeIntervalSince1970: 0),
            startedAt: started,
            completedAt: ended,
            result: result,
            lastEventKind: nil,
            lastEventAt: nil
        )
    }

    private static func readTrimmed(_ url: URL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

extension HermesKanbanService.KanbanTask {
    var isActive: Bool { status == "running" }
    var isQueued: Bool { status == "ready" || status == "todo" || status == "triage" }
    var isRecent: Bool { status == "done" || status == "blocked" }

    var displayAssignee: String { assignee ?? "—" }

    var workspaceShortPath: String? {
        guard let workspacePath else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workspacePath.hasPrefix(home) {
            return "~" + workspacePath.dropFirst(home.count)
        }
        return workspacePath
    }
}
