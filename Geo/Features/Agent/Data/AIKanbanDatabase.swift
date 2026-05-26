import Foundation
import GRDB
import os.log

private let kanbanLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "AIKanban")

final class AIKanbanDatabase: @unchecked Sendable {
    private var dbQueue: DatabaseQueue
    private let queue = DispatchQueue(label: "com.geo.ai-kanban", qos: .userInitiated)
    private let fileURL: URL

    init(databaseURL: URL? = nil, fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let resolvedURL = databaseURL
            ?? baseURL.appendingPathComponent("Geo/Symphony/kanban.db")
        try? fileManager.createDirectory(at: resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.fileURL = resolvedURL
        self.dbQueue = Self.openOrRecreate(at: resolvedURL, fileManager: fileManager)
        Self.applyPragmas(to: dbQueue)
        let migrator = Self.buildMigrator()
        if (try? migrator.migrate(dbQueue)) == nil {
            kanbanLogger.fault("Kanban migration failed — recreating")
            Self.backup(at: resolvedURL, fileManager: fileManager)
            dbQueue = Self.forceRecreate(at: resolvedURL, fileManager: fileManager)
            Self.applyPragmas(to: dbQueue)
            try? migrator.migrate(dbQueue)
        }
    }

    var location: URL { fileURL }

    private static func openOrRecreate(at url: URL, fileManager: FileManager) -> DatabaseQueue {
        if let q = try? DatabaseQueue(path: url.path) { return q }
        return forceRecreate(at: url, fileManager: fileManager)
    }

    private static func forceRecreate(at url: URL, fileManager: FileManager) -> DatabaseQueue {
        try? fileManager.removeItem(at: url)
        if let q = try? DatabaseQueue(path: url.path) { return q }
        kanbanLogger.error("Cannot create kanban DB at \(url.path); using in-memory")
        return (try? DatabaseQueue()) ?? DatabaseQueue.makeMemoryFallback()
    }

    @discardableResult
    private static func backup(at url: URL, fileManager: FileManager) -> URL? {
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("kanban.db.backup-\(Int(Date().timeIntervalSince1970))")
        do {
            try fileManager.copyItem(at: url, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }

    private static func applyPragmas(to dbQueue: DatabaseQueue) {
        try? dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
    }

    private static func buildMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createKanban") { db in
            try db.create(table: "tasks") { t in
                t.column("id", .text).primaryKey()
                t.column("identifier", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("profile", .text)
                t.column("status", .text).notNull().defaults(to: "todo")
                t.column("priority", .integer)
                t.column("workspace_path", .text)
                t.column("idempotency_key", .text)
                t.column("max_runtime_seconds", .integer)
                t.column("claim_lock", .text)
                t.column("claim_lock_expires_at", .datetime)
                t.column("claim_lock_run_id", .text)
                t.column("board", .text).notNull().defaults(to: "default")
                t.column("tenant", .text)
                t.column("linked_block_id", .text)
                t.column("consecutive_failures", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_tasks_status", on: "tasks", columns: ["status"])
            try db.create(index: "idx_tasks_profile", on: "tasks", columns: ["profile"])
            try db.create(index: "idx_tasks_claim_lock", on: "tasks", columns: ["claim_lock"])
            try db.create(index: "idx_tasks_idempotency", on: "tasks", columns: ["idempotency_key"])
            try db.create(index: "idx_tasks_board", on: "tasks", columns: ["board"])
            try db.create(index: "idx_tasks_identifier", on: "tasks", columns: ["identifier"])

            try db.create(table: "task_runs") { t in
                t.column("id", .text).primaryKey()
                t.column("task_id", .text).notNull()
                t.column("attempt", .integer).notNull()
                t.column("profile", .text)
                t.column("agent", .text)
                t.column("workspace_path", .text)
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime)
                t.column("last_heartbeat_at", .datetime)
                t.column("outcome", .text)
                t.column("summary", .text)
                t.column("metadata_json", .text)
                t.column("result_json", .text)
                t.column("error_message", .text)
                t.column("pid", .integer)
                t.foreignKey(["task_id"], references: "tasks", columns: ["id"], onDelete: .cascade)
            }
            try db.create(index: "idx_runs_task", on: "task_runs", columns: ["task_id"])
            try db.create(index: "idx_runs_outcome", on: "task_runs", columns: ["outcome"])

            try db.create(table: "task_links") { t in
                t.column("parent_id", .text).notNull()
                t.column("child_id", .text).notNull()
                t.primaryKey(["parent_id", "child_id"])
                t.foreignKey(["parent_id"], references: "tasks", columns: ["id"], onDelete: .cascade)
                t.foreignKey(["child_id"], references: "tasks", columns: ["id"], onDelete: .cascade)
            }
            try db.create(index: "idx_links_child", on: "task_links", columns: ["child_id"])

            try db.create(table: "task_comments") { t in
                t.column("id", .text).primaryKey()
                t.column("task_id", .text).notNull()
                t.column("author", .text).notNull()
                t.column("body", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.foreignKey(["task_id"], references: "tasks", columns: ["id"], onDelete: .cascade)
            }
            try db.create(index: "idx_comments_task", on: "task_comments", columns: ["task_id"])

            try db.create(table: "task_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("task_id", .text)
                t.column("run_id", .text)
                t.column("kind", .text).notNull()
                t.column("payload_json", .text)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_events_task", on: "task_events", columns: ["task_id"])
            try db.create(index: "idx_events_run", on: "task_events", columns: ["run_id"])
            try db.create(index: "idx_events_kind", on: "task_events", columns: ["kind"])
        }
        return migrator
    }

    func read<T>(_ work: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try self.dbQueue.read(work)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func write<T>(_ work: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try self.dbQueue.write(work)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
