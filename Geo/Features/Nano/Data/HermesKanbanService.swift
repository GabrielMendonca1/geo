import Combine
import Foundation
import GRDB

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

    private static let dbURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".hermes/kanban.db")

    private var queue: DatabaseQueue?
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
        queue = nil
        dbAvailable = false
    }

    private func openIfNeeded() -> DatabaseQueue? {
        if let queue { return queue }
        let path = Self.dbURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            dbAvailable = false
            return nil
        }
        do {
            var config = Configuration()
            config.readonly = true
            let q = try DatabaseQueue(path: path, configuration: config)
            queue = q
            dbAvailable = true
            return q
        } catch {
            lastError = "open kanban.db: \(error.localizedDescription)"
            dbAvailable = false
            return nil
        }
    }

    private func tick() async {
        guard let q = openIfNeeded() else { return }
        do {
            let rows = try q.read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    SELECT t.id, t.title, t.assignee, t.status, t.workspace_kind,
                           t.workspace_path, t.priority, t.created_at, t.started_at,
                           t.completed_at, t.result,
                           (SELECT kind FROM task_events
                              WHERE task_id = t.id ORDER BY id DESC LIMIT 1) AS last_kind,
                           (SELECT created_at FROM task_events
                              WHERE task_id = t.id ORDER BY id DESC LIMIT 1) AS last_at
                      FROM tasks t
                     WHERE t.status IN ('running','ready','blocked','todo','triage')
                        OR (t.status = 'done'
                            AND COALESCE(t.completed_at, 0) > strftime('%s','now') - 86400)
                     ORDER BY
                       CASE t.status
                         WHEN 'running' THEN 0
                         WHEN 'ready'   THEN 1
                         WHEN 'blocked' THEN 2
                         WHEN 'todo'    THEN 3
                         WHEN 'triage'  THEN 4
                         ELSE 5
                       END,
                       COALESCE(t.started_at, t.created_at) DESC
                     LIMIT 80
                """)
            }
            let mapped = rows.map(Self.row)
            if mapped != tasks { tasks = mapped }
            if lastError != nil { lastError = nil }
        } catch {
            // Hermes WAL checkpoint or schema migrations can transiently
            // break the read; surface the error but keep polling.
            lastError = error.localizedDescription
            queue = nil
        }
    }

    private static func row(_ r: Row) -> KanbanTask {
        func unixDate(_ k: String) -> Date? {
            guard let n: Int64 = r[k] else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(n))
        }
        return KanbanTask(
            id: r["id"] ?? "",
            title: r["title"] ?? "",
            assignee: r["assignee"],
            status: r["status"] ?? "",
            workspaceKind: r["workspace_kind"] ?? "",
            workspacePath: r["workspace_path"],
            priority: r["priority"] ?? 0,
            createdAt: unixDate("created_at") ?? Date(timeIntervalSince1970: 0),
            startedAt: unixDate("started_at"),
            completedAt: unixDate("completed_at"),
            result: r["result"],
            lastEventKind: r["last_kind"],
            lastEventAt: unixDate("last_at")
        )
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
