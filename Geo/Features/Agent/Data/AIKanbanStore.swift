import Foundation
import GRDB

actor AIKanbanStore {
    static let shared = AIKanbanStore()

    private let database: AIKanbanDatabase
    private let circuitBreakerLimit: Int

    init(database: AIKanbanDatabase = AIKanbanDatabase(), circuitBreakerLimit: Int = 5) {
        self.database = database
        self.circuitBreakerLimit = circuitBreakerLimit
    }

    var databaseURL: URL { database.location }

    func upsertTask(_ task: AIKanbanTask) async throws {
        try await database.write { db in
            try Self.upsertTask(task, in: db)
            try Self.insertEvent(
                AIKanbanEvent(
                    id: 0,
                    taskID: task.id,
                    runID: nil,
                    kind: .edited,
                    payloadJSON: nil,
                    createdAt: Date()
                ),
                in: db
            )
        }
    }

    func createTaskIfAbsent(
        id: String,
        identifier: String,
        title: String,
        body: String = "",
        profile: String? = nil,
        priority: Int? = nil,
        idempotencyKey: String? = nil,
        linkedBlockID: String? = nil,
        status: AIKanbanStatus = .todo,
        board: String = "default"
    ) async throws -> (task: AIKanbanTask, created: Bool) {
        try await database.write { db in
            if let key = idempotencyKey, !key.isEmpty,
               let existing = try Self.fetchTask(byIdempotencyKey: key, in: db) {
                return (existing, false)
            }
            if let existing = try Self.fetchTask(id: id, in: db) {
                return (existing, false)
            }
            let now = Date()
            let task = AIKanbanTask(
                id: id,
                identifier: identifier,
                title: title,
                body: body,
                profile: profile,
                status: status,
                priority: priority,
                workspacePath: nil,
                idempotencyKey: idempotencyKey,
                maxRuntimeSeconds: nil,
                claimLock: nil,
                claimLockExpiresAt: nil,
                claimLockRunID: nil,
                board: board,
                tenant: nil,
                linkedBlockID: linkedBlockID,
                consecutiveFailures: 0,
                createdAt: now,
                updatedAt: now
            )
            try Self.upsertTask(task, in: db)
            try Self.insertEvent(
                AIKanbanEvent(id: 0, taskID: id, runID: nil, kind: .created, payloadJSON: nil, createdAt: now),
                in: db
            )
            return (task, true)
        }
    }

    func updateStatus(taskID: String, to status: AIKanbanStatus, payload: [String: Any]? = nil) async throws {
        try await database.write { db in
            guard var task = try Self.fetchTask(id: taskID, in: db) else { return }
            let previous = task.status
            task.status = status
            task.updatedAt = Date()
            if status.isTerminal {
                task.claimLock = nil
                task.claimLockExpiresAt = nil
                task.claimLockRunID = nil
            }
            try Self.upsertTask(task, in: db)
            let json = Self.json(["from": previous.rawValue, "to": status.rawValue, "extra": payload as Any])
            try Self.insertEvent(
                AIKanbanEvent(id: 0, taskID: taskID, runID: nil, kind: .statusChanged, payloadJSON: json, createdAt: Date()),
                in: db
            )
        }
    }

    func setProfile(taskID: String, profile: String?) async throws {
        try await database.write { db in
            guard var task = try Self.fetchTask(id: taskID, in: db) else { return }
            task.profile = profile
            task.updatedAt = Date()
            try Self.upsertTask(task, in: db)
        }
    }

    func setLinkedBlock(taskID: String, blockID: String?) async throws {
        try await database.write { db in
            guard var task = try Self.fetchTask(id: taskID, in: db) else { return }
            task.linkedBlockID = blockID
            task.updatedAt = Date()
            try Self.upsertTask(task, in: db)
        }
    }

    func setTitle(taskID: String, title: String, body: String? = nil) async throws {
        try await database.write { db in
            guard var task = try Self.fetchTask(id: taskID, in: db) else { return }
            task.title = title
            if let body { task.body = body }
            task.updatedAt = Date()
            try Self.upsertTask(task, in: db)
        }
    }

    func deleteTask(id: String) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [id])
        }
    }

    func task(id: String) async throws -> AIKanbanTask? {
        try await database.read { db in try Self.fetchTask(id: id, in: db) }
    }

    func allTasks(board: String? = nil) async throws -> [AIKanbanTask] {
        try await database.read { db in
            if let board {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM tasks WHERE board = ? ORDER BY created_at ASC", arguments: [board])
                return rows.map(Self.decodeTask(from:))
            }
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM tasks ORDER BY created_at ASC")
            return rows.map(Self.decodeTask(from:))
        }
    }

    func tryClaim(profile: String, ttlSeconds: Int) async throws -> AIKanbanClaim? {
        try await database.write { db in
            let now = Date()
            let candidates = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM tasks
                WHERE status = 'ready' AND claim_lock IS NULL
                ORDER BY priority IS NULL, priority ASC, created_at ASC
                """
            )
            guard let row = candidates.first(where: { row in
                let taskProfile = row["profile"] as String?
                guard let taskProfile, !taskProfile.isEmpty else { return true }
                return taskProfile == profile
            }) else { return nil }

            var task = Self.decodeTask(from: row)
            let runID = "run_\(UUID().uuidString.lowercased())"
            let lease = "lease_\(UUID().uuidString.prefix(12))"
            let expiresAt = now.addingTimeInterval(Double(ttlSeconds))
            let attempt = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(attempt), 0) + 1 FROM task_runs WHERE task_id = ?",
                arguments: [task.id]
            ) ?? 1

            try db.execute(
                sql: """
                UPDATE tasks SET
                    claim_lock = ?, claim_lock_expires_at = ?, claim_lock_run_id = ?,
                    status = 'running', updated_at = ?
                WHERE id = ? AND claim_lock IS NULL AND status = 'ready'
                """,
                arguments: [lease, expiresAt, runID, now, task.id]
            )
            guard db.changesCount > 0 else { return nil }

            task.claimLock = lease
            task.claimLockExpiresAt = expiresAt
            task.claimLockRunID = runID
            task.status = .running
            task.updatedAt = now

            let run = AIKanbanRun(
                id: runID,
                taskID: task.id,
                attempt: attempt,
                profile: profile,
                agent: nil,
                workspacePath: task.workspacePath,
                startedAt: now,
                endedAt: nil,
                lastHeartbeatAt: now,
                outcome: nil,
                summary: nil,
                metadataJSON: nil,
                resultJSON: nil,
                errorMessage: nil,
                pid: nil
            )
            try Self.insertRun(run, in: db)
            let payload = Self.json(["lease": lease, "ttl": ttlSeconds, "profile": profile, "attempt": attempt])
            try Self.insertEvent(
                AIKanbanEvent(id: 0, taskID: task.id, runID: runID, kind: .claimed, payloadJSON: payload, createdAt: now),
                in: db
            )
            return AIKanbanClaim(task: task, runID: runID, attempt: attempt, lease: lease, expiresAt: expiresAt)
        }
    }

    func attachRunMetadata(runID: String, agent: String?, workspacePath: String?, pid: Int32?) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE task_runs SET agent = COALESCE(?, agent),
                                     workspace_path = COALESCE(?, workspace_path),
                                     pid = COALESCE(?, pid)
                WHERE id = ?
                """,
                arguments: [agent, workspacePath, pid.flatMap { Int64(exactly: $0) }, runID]
            )
        }
    }

    func extendClaim(taskID: String, ttlSeconds: Int) async throws {
        try await database.write { db in
            let expiresAt = Date().addingTimeInterval(Double(ttlSeconds))
            try db.execute(
                sql: "UPDATE tasks SET claim_lock_expires_at = ?, updated_at = ? WHERE id = ? AND claim_lock IS NOT NULL",
                arguments: [expiresAt, Date(), taskID]
            )
        }
    }

    func heartbeat(runID: String, note: String?) async throws {
        try await database.write { db in
            let now = Date()
            try db.execute(
                sql: "UPDATE task_runs SET last_heartbeat_at = ? WHERE id = ?",
                arguments: [now, runID]
            )
            if let row = try Row.fetchOne(db, sql: "SELECT task_id, claim_lock_expires_at FROM tasks WHERE claim_lock_run_id = ?", arguments: [runID]) {
                let taskID: String = row["task_id"]
                let payload: String? = note.flatMap { Self.json(["note": $0]) }
                try Self.insertEvent(
                    AIKanbanEvent(id: 0, taskID: taskID, runID: runID, kind: .heartbeat, payloadJSON: payload, createdAt: now),
                    in: db
                )
            }
        }
    }

    func completeRun(
        runID: String,
        outcome: AIKanbanOutcome,
        summary: String?,
        metadataJSON: String?,
        resultJSON: String?,
        errorMessage: String?
    ) async throws {
        try await database.write { db in
            let now = Date()
            guard let run = try Self.fetchRun(id: runID, in: db),
                  let task = try Self.fetchTask(id: run.taskID, in: db) else { return }

            try db.execute(
                sql: """
                UPDATE task_runs SET
                    ended_at = ?, outcome = ?, summary = ?, metadata_json = ?, result_json = ?, error_message = ?
                WHERE id = ?
                """,
                arguments: [now, outcome.rawValue, summary, metadataJSON, resultJSON, errorMessage, runID]
            )

            var updated = task
            updated.updatedAt = now
            updated.claimLock = nil
            updated.claimLockExpiresAt = nil
            updated.claimLockRunID = nil

            let nextStatus: AIKanbanStatus
            switch outcome {
            case .completed:
                nextStatus = .done
                updated.consecutiveFailures = 0
            case .blocked:
                nextStatus = .blocked
            case .canceled:
                nextStatus = .ready
            case .crashed, .timedOut, .reclaimed, .spawnFailed:
                updated.consecutiveFailures += 1
                if updated.consecutiveFailures >= self.circuitBreakerLimit {
                    nextStatus = .blocked
                } else {
                    nextStatus = .ready
                }
            case .gaveUp:
                nextStatus = .blocked
            }
            updated.status = nextStatus

            try Self.upsertTask(updated, in: db)

            let payload = Self.json([
                "outcome": outcome.rawValue,
                "attempt": run.attempt,
                "summary": summary as Any,
                "consecutive_failures": updated.consecutiveFailures
            ])
            let kind: AIKanbanEventKind
            switch outcome {
            case .completed: kind = .completed
            case .blocked: kind = .blocked
            case .canceled: kind = .reclaimed
            case .crashed: kind = .crashed
            case .timedOut: kind = .timedOut
            case .reclaimed: kind = .reclaimed
            case .spawnFailed: kind = .spawnFailed
            case .gaveUp: kind = .gaveUp
            }
            try Self.insertEvent(
                AIKanbanEvent(id: 0, taskID: task.id, runID: runID, kind: kind, payloadJSON: payload, createdAt: now),
                in: db
            )

            if updated.status == .blocked && updated.consecutiveFailures >= self.circuitBreakerLimit {
                let breakerPayload = Self.json([
                    "reason": "circuit_breaker",
                    "consecutive_failures": updated.consecutiveFailures
                ])
                try Self.insertEvent(
                    AIKanbanEvent(id: 0, taskID: task.id, runID: nil, kind: .gaveUp, payloadJSON: breakerPayload, createdAt: now),
                    in: db
                )
            }
        }
    }

    func reapStaleClaims(now: Date = Date()) async throws -> [String] {
        try await database.write { db in
            let stale = try Row.fetchAll(
                db,
                sql: """
                SELECT id, claim_lock_run_id FROM tasks
                WHERE claim_lock IS NOT NULL AND claim_lock_expires_at IS NOT NULL AND claim_lock_expires_at < ?
                """,
                arguments: [now]
            )
            var reaped: [String] = []
            for row in stale {
                let taskID: String = row["id"]
                let runID = row["claim_lock_run_id"] as String?
                try db.execute(
                    sql: """
                    UPDATE tasks SET status = 'ready',
                                     claim_lock = NULL,
                                     claim_lock_expires_at = NULL,
                                     claim_lock_run_id = NULL,
                                     consecutive_failures = consecutive_failures + 1,
                                     updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [now, taskID]
                )
                if let runID {
                    try db.execute(
                        sql: "UPDATE task_runs SET ended_at = ?, outcome = 'reclaimed' WHERE id = ? AND ended_at IS NULL",
                        arguments: [now, runID]
                    )
                }
                let payload = Self.json(["reason": "claim_expired"])
                try Self.insertEvent(
                    AIKanbanEvent(id: 0, taskID: taskID, runID: runID, kind: .reclaimed, payloadJSON: payload, createdAt: now),
                    in: db
                )
                reaped.append(taskID)
            }
            return reaped
        }
    }

    func promoteReady() async throws -> [String] {
        try await database.write { db in
            let now = Date()
            let candidates = try String.fetchAll(db, sql: "SELECT id FROM tasks WHERE status = 'todo'")
            var promoted: [String] = []
            for taskID in candidates {
                let parents = try String.fetchAll(
                    db,
                    sql: "SELECT parent_id FROM task_links WHERE child_id = ?",
                    arguments: [taskID]
                )
                if !parents.isEmpty {
                    let pendingParents = try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM tasks
                        WHERE id IN (\(parents.map { _ in "?" }.joined(separator: ",")))
                          AND status NOT IN ('done', 'archived')
                        """,
                        arguments: StatementArguments(parents)
                    ) ?? 0
                    guard pendingParents == 0 else { continue }
                }
                try db.execute(
                    sql: "UPDATE tasks SET status = 'ready', updated_at = ? WHERE id = ?",
                    arguments: [now, taskID]
                )
                let payload = Self.json(["from": "todo", "to": "ready"])
                try Self.insertEvent(
                    AIKanbanEvent(id: 0, taskID: taskID, runID: nil, kind: .promoted, payloadJSON: payload, createdAt: now),
                    in: db
                )
                promoted.append(taskID)
            }
            return promoted
        }
    }

    func addComment(taskID: String, author: String, body: String) async throws -> AIKanbanComment {
        try await database.write { db in
            let now = Date()
            let id = "cm_\(UUID().uuidString.lowercased())"
            try db.execute(
                sql: "INSERT INTO task_comments (id, task_id, author, body, created_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, taskID, author, body, now]
            )
            let payload = Self.json(["author": author, "preview": String(body.prefix(120))])
            try Self.insertEvent(
                AIKanbanEvent(id: 0, taskID: taskID, runID: nil, kind: .commentAdded, payloadJSON: payload, createdAt: now),
                in: db
            )
            return AIKanbanComment(id: id, taskID: taskID, author: author, body: body, createdAt: now)
        }
    }

    func comments(taskID: String) async throws -> [AIKanbanComment] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM task_comments WHERE task_id = ? ORDER BY created_at ASC",
                arguments: [taskID]
            )
            return rows.map { row in
                AIKanbanComment(
                    id: row["id"],
                    taskID: row["task_id"],
                    author: row["author"],
                    body: row["body"],
                    createdAt: row["created_at"]
                )
            }
        }
    }

    func addLink(parentID: String, childID: String) async throws {
        try await database.write { db in
            guard parentID != childID else { return }
            try db.execute(
                sql: "INSERT OR IGNORE INTO task_links (parent_id, child_id) VALUES (?, ?)",
                arguments: [parentID, childID]
            )
            let payload = Self.json(["parent": parentID, "child": childID])
            try Self.insertEvent(
                AIKanbanEvent(id: 0, taskID: childID, runID: nil, kind: .linked, payloadJSON: payload, createdAt: Date()),
                in: db
            )
        }
    }

    func removeLink(parentID: String, childID: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM task_links WHERE parent_id = ? AND child_id = ?",
                arguments: [parentID, childID]
            )
            let payload = Self.json(["parent": parentID, "child": childID])
            try Self.insertEvent(
                AIKanbanEvent(id: 0, taskID: childID, runID: nil, kind: .unlinked, payloadJSON: payload, createdAt: Date()),
                in: db
            )
        }
    }

    func parents(of taskID: String) async throws -> [AIKanbanTask] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT tasks.* FROM tasks
                JOIN task_links ON task_links.parent_id = tasks.id
                WHERE task_links.child_id = ?
                ORDER BY tasks.created_at ASC
                """,
                arguments: [taskID]
            )
            return rows.map(Self.decodeTask(from:))
        }
    }

    func children(of taskID: String) async throws -> [AIKanbanTask] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT tasks.* FROM tasks
                JOIN task_links ON task_links.child_id = tasks.id
                WHERE task_links.parent_id = ?
                ORDER BY tasks.created_at ASC
                """,
                arguments: [taskID]
            )
            return rows.map(Self.decodeTask(from:))
        }
    }

    func handoffsForChild(_ childID: String) async throws -> [AIKanbanHandoff] {
        try await database.read { db in
            let parents = try Row.fetchAll(
                db,
                sql: """
                SELECT tasks.id, tasks.identifier FROM tasks
                JOIN task_links ON task_links.parent_id = tasks.id
                WHERE task_links.child_id = ?
                """,
                arguments: [childID]
            )
            var result: [AIKanbanHandoff] = []
            for row in parents {
                let parentID: String = row["id"]
                let parentIdentifier: String = row["identifier"]
                let runRow = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT summary, metadata_json, result_json FROM task_runs
                    WHERE task_id = ? AND outcome = 'completed'
                    ORDER BY ended_at DESC LIMIT 1
                    """,
                    arguments: [parentID]
                )
                result.append(AIKanbanHandoff(
                    parentTaskID: parentID,
                    parentIdentifier: parentIdentifier,
                    summary: runRow?["summary"] as String?,
                    metadataJSON: runRow?["metadata_json"] as String?,
                    resultJSON: runRow?["result_json"] as String?
                ))
            }
            return result
        }
    }

    func runs(taskID: String) async throws -> [AIKanbanRun] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM task_runs WHERE task_id = ? ORDER BY started_at DESC",
                arguments: [taskID]
            )
            return rows.map(Self.decodeRun(from:))
        }
    }

    func recentEvents(limit: Int = 100) async throws -> [AIKanbanEvent] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM task_events ORDER BY id DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.map(Self.decodeEvent(from:))
        }
    }

    func block(taskID: String, reason: String) async throws {
        try await database.write { db in
            guard var task = try Self.fetchTask(id: taskID, in: db) else { return }
            task.status = .blocked
            task.updatedAt = Date()
            task.claimLock = nil
            task.claimLockExpiresAt = nil
            task.claimLockRunID = nil
            try Self.upsertTask(task, in: db)
            let payload = Self.json(["reason": reason])
            try Self.insertEvent(
                AIKanbanEvent(id: 0, taskID: taskID, runID: nil, kind: .blocked, payloadJSON: payload, createdAt: Date()),
                in: db
            )
        }
    }

    func unblock(taskID: String) async throws {
        try await database.write { db in
            guard var task = try Self.fetchTask(id: taskID, in: db) else { return }
            task.status = .ready
            task.consecutiveFailures = 0
            task.updatedAt = Date()
            try Self.upsertTask(task, in: db)
            try Self.insertEvent(
                AIKanbanEvent(id: 0, taskID: taskID, runID: nil, kind: .unblocked, payloadJSON: nil, createdAt: Date()),
                in: db
            )
        }
    }

    func archive(taskID: String) async throws {
        try await database.write { db in
            guard var task = try Self.fetchTask(id: taskID, in: db) else { return }
            task.status = .archived
            task.claimLock = nil
            task.claimLockExpiresAt = nil
            task.claimLockRunID = nil
            task.updatedAt = Date()
            try Self.upsertTask(task, in: db)
            try Self.insertEvent(
                AIKanbanEvent(id: 0, taskID: taskID, runID: nil, kind: .archived, payloadJSON: nil, createdAt: Date()),
                in: db
            )
        }
    }

    func recordHandoffApplied(taskID: String, runID: String, parents: [AIKanbanHandoff]) async throws {
        guard !parents.isEmpty else { return }
        try await database.write { db in
            let payload = Self.json(["parents": parents.map(\.parentTaskID)])
            try Self.insertEvent(
                AIKanbanEvent(id: 0, taskID: taskID, runID: runID, kind: .handoffApplied, payloadJSON: payload, createdAt: Date()),
                in: db
            )
        }
    }

    func setMaxRuntime(taskID: String, seconds: Int?) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE tasks SET max_runtime_seconds = ?, updated_at = ? WHERE id = ?",
                arguments: [seconds, Date(), taskID]
            )
        }
    }

    func ensureTaskFromIssue(_ issue: AIIssue) async throws -> AIKanbanTask {
        let mapped = AIKanbanStatus.fromIssueState(issue.state)
        let result = try await createTaskIfAbsent(
            id: issue.id,
            identifier: issue.identifier,
            title: issue.title,
            body: issue.description ?? "",
            profile: nil,
            priority: issue.priority,
            idempotencyKey: nil,
            linkedBlockID: issue.linkedBlockID,
            status: mapped
        )
        if !result.created {
            try await database.write { db in
                guard var task = try Self.fetchTask(id: issue.id, in: db) else { return }
                task.title = issue.title
                task.body = issue.description ?? task.body
                task.priority = issue.priority ?? task.priority
                task.linkedBlockID = issue.linkedBlockID ?? task.linkedBlockID
                if !task.status.isTerminal && task.status != .running {
                    let mappedStatus = AIKanbanStatus.fromIssueState(issue.state)
                    task.status = mappedStatus
                }
                task.updatedAt = Date()
                try Self.upsertTask(task, in: db)
            }
            return try await task(id: issue.id) ?? result.task
        }
        return result.task
    }

    func currentRunForTask(_ taskID: String) async throws -> AIKanbanRun? {
        try await database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM task_runs WHERE task_id = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1",
                arguments: [taskID]
            )
            return row.map(Self.decodeRun(from:))
        }
    }

    private static func upsertTask(_ task: AIKanbanTask, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO tasks (
                id, identifier, title, body, profile, status, priority, workspace_path,
                idempotency_key, max_runtime_seconds, claim_lock, claim_lock_expires_at,
                claim_lock_run_id, board, tenant, linked_block_id, consecutive_failures,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                identifier = excluded.identifier,
                title = excluded.title,
                body = excluded.body,
                profile = excluded.profile,
                status = excluded.status,
                priority = excluded.priority,
                workspace_path = excluded.workspace_path,
                idempotency_key = excluded.idempotency_key,
                max_runtime_seconds = excluded.max_runtime_seconds,
                claim_lock = excluded.claim_lock,
                claim_lock_expires_at = excluded.claim_lock_expires_at,
                claim_lock_run_id = excluded.claim_lock_run_id,
                board = excluded.board,
                tenant = excluded.tenant,
                linked_block_id = excluded.linked_block_id,
                consecutive_failures = excluded.consecutive_failures,
                updated_at = excluded.updated_at
            """,
            arguments: [
                task.id, task.identifier, task.title, task.body, task.profile, task.status.rawValue,
                task.priority, task.workspacePath, task.idempotencyKey, task.maxRuntimeSeconds,
                task.claimLock, task.claimLockExpiresAt, task.claimLockRunID, task.board, task.tenant,
                task.linkedBlockID, task.consecutiveFailures, task.createdAt, task.updatedAt
            ]
        )
    }

    private static func insertRun(_ run: AIKanbanRun, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO task_runs (
                id, task_id, attempt, profile, agent, workspace_path, started_at, ended_at,
                last_heartbeat_at, outcome, summary, metadata_json, result_json, error_message, pid
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                run.id, run.taskID, run.attempt, run.profile, run.agent, run.workspacePath,
                run.startedAt, run.endedAt, run.lastHeartbeatAt, run.outcome?.rawValue,
                run.summary, run.metadataJSON, run.resultJSON, run.errorMessage,
                run.pid.flatMap { Int64(exactly: $0) }
            ]
        )
    }

    private static func insertEvent(_ event: AIKanbanEvent, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO task_events (task_id, run_id, kind, payload_json, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [event.taskID, event.runID, event.kind.rawValue, event.payloadJSON, event.createdAt]
        )
    }

    private static func fetchTask(id: String, in db: Database) throws -> AIKanbanTask? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return decodeTask(from: row)
    }

    private static func fetchTask(byIdempotencyKey key: String, in db: Database) throws -> AIKanbanTask? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM tasks WHERE idempotency_key = ? LIMIT 1",
            arguments: [key]
        ) else { return nil }
        return decodeTask(from: row)
    }

    private static func fetchRun(id: String, in db: Database) throws -> AIKanbanRun? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM task_runs WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return decodeRun(from: row)
    }

    private static func decodeTask(from row: Row) -> AIKanbanTask {
        AIKanbanTask(
            id: row["id"],
            identifier: row["identifier"],
            title: row["title"],
            body: row["body"],
            profile: row["profile"],
            status: AIKanbanStatus(rawValue: row["status"]) ?? .todo,
            priority: row["priority"],
            workspacePath: row["workspace_path"],
            idempotencyKey: row["idempotency_key"],
            maxRuntimeSeconds: row["max_runtime_seconds"],
            claimLock: row["claim_lock"],
            claimLockExpiresAt: row["claim_lock_expires_at"],
            claimLockRunID: row["claim_lock_run_id"],
            board: row["board"],
            tenant: row["tenant"],
            linkedBlockID: row["linked_block_id"],
            consecutiveFailures: row["consecutive_failures"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func decodeRun(from row: Row) -> AIKanbanRun {
        AIKanbanRun(
            id: row["id"],
            taskID: row["task_id"],
            attempt: row["attempt"],
            profile: row["profile"],
            agent: row["agent"],
            workspacePath: row["workspace_path"],
            startedAt: row["started_at"],
            endedAt: row["ended_at"],
            lastHeartbeatAt: row["last_heartbeat_at"],
            outcome: (row["outcome"] as String?).flatMap(AIKanbanOutcome.init(rawValue:)),
            summary: row["summary"],
            metadataJSON: row["metadata_json"],
            resultJSON: row["result_json"],
            errorMessage: row["error_message"],
            pid: (row["pid"] as Int64?).map(Int32.init)
        )
    }

    private static func decodeEvent(from row: Row) -> AIKanbanEvent {
        AIKanbanEvent(
            id: row["id"],
            taskID: row["task_id"],
            runID: row["run_id"],
            kind: AIKanbanEventKind(rawValue: row["kind"]) ?? .edited,
            payloadJSON: row["payload_json"],
            createdAt: row["created_at"]
        )
    }

    private static func json(_ object: [String: Any]) -> String? {
        let cleaned = object.compactMapValues { value -> Any? in
            if value is NSNull { return nil }
            if let str = value as? String, str.isEmpty { return nil }
            return value
        }
        guard !cleaned.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }
}

