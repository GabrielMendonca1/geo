import Foundation
import GRDB
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "DatabaseService")

struct BlockIndexEntry: Equatable {
    let id: String
    let path: String
    let title: String
    let content: String
    let createdAt: Date
    let modifiedAt: Date
    let tagId: String?
    let dayId: String?
    let openTaskCount: Int
    let completedTaskCount: Int
    let tags: [String]
    let type: String
    let status: String?
    let layer: String
    let isFullWidth: Bool

    init(
        id: String,
        path: String,
        title: String,
        content: String,
        createdAt: Date,
        modifiedAt: Date,
        tagId: String?,
        dayId: String?,
        openTaskCount: Int,
        completedTaskCount: Int,
        tags: [String],
        type: String = "fleeting",
        status: String? = nil,
        layer: String = "user",
        isFullWidth: Bool = false
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.tagId = tagId
        self.dayId = dayId
        self.openTaskCount = openTaskCount
        self.completedTaskCount = completedTaskCount
        self.tags = tags
        self.type = type
        self.status = status
        self.layer = layer
        self.isFullWidth = isFullWidth
    }
}

final class DatabaseService: @unchecked Sendable {
    static let shared = DatabaseService()

    private var dbQueue: DatabaseQueue
    private let queue = DispatchQueue(label: "com.geo.database", qos: .userInitiated)

    init(databaseURL: URL? = nil, fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let resolvedURL = databaseURL
            ?? baseURL.appendingPathComponent("Geo/Index/blocks.sqlite")
        try? fileManager.createDirectory(at: resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        dbQueue = Self.openOrRecreate(at: resolvedURL, fileManager: fileManager)
        let m = Self.buildMigrator()
        if (try? m.migrate(dbQueue)) == nil {
            logger.fault("Database migration failed — backing up before recreating")
            Self.backupDatabase(at: resolvedURL, fileManager: fileManager)
            let fresh = Self.forceRecreate(at: resolvedURL, fileManager: fileManager)
            dbQueue = fresh
            do {
                try m.migrate(dbQueue)
            } catch {
                logger.fault("Fresh database migration also failed: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private static func backupDatabase(at url: URL, fileManager: FileManager) -> URL? {
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("blocks.sqlite.backup-\(Int(Date().timeIntervalSince1970))")
        do {
            try fileManager.copyItem(at: url, to: backupURL)
            logger.info("Database backed up to \(backupURL.lastPathComponent)")
            return backupURL
        } catch {
            logger.error("Failed to backup database: \(error.localizedDescription)")
            return nil
        }
    }

    private static func openOrRecreate(at url: URL, fileManager: FileManager) -> DatabaseQueue {
        if let q = try? DatabaseQueue(path: url.path) { return q }
        return forceRecreate(at: url, fileManager: fileManager)
    }

    private static func forceRecreate(at url: URL, fileManager: FileManager) -> DatabaseQueue {
        try? fileManager.removeItem(at: url)
        if let q = try? DatabaseQueue(path: url.path) { return q }
        logger.error("Cannot create on-disk DB at \(url.path), falling back to in-memory")
        return (try? DatabaseQueue()) ?? DatabaseQueue.makeMemoryFallback()
    }

    private static func buildMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createBlocks") { db in
            try db.create(table: "blocks") { t in
                t.column("id", .text).primaryKey()
                t.column("path", .text).notNull()
                t.column("title", .text).notNull()
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("tagId", .text)
                t.column("dayId", .text)
                t.column("openTaskCount", .integer).notNull().defaults(to: 0)
                t.column("completedTaskCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "block_tags") { t in
                t.column("blockId", .text).notNull()
                t.column("tag", .text).notNull()
                t.primaryKey(["blockId", "tag"])
            }
            try db.create(index: "block_tags_tag", on: "block_tags", columns: ["tag"])
            try db.create(virtualTable: "blocks_fts", using: FTS5()) { t in
                t.column("blockId")
                t.column("title")
                t.column("content")
            }
        }
        migrator.registerMigration("dropBlocksFrontmatter") { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(blocks)")
            let hasFrontmatter = columns.contains { row in
                let name: String = row["name"]
                return name == "frontmatter"
            }
            guard hasFrontmatter else { return }

            try db.execute(sql: """
                CREATE TABLE blocks_new (
                    id TEXT PRIMARY KEY,
                    path TEXT NOT NULL,
                    title TEXT NOT NULL,
                    content TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    modifiedAt DATETIME NOT NULL,
                    tagId TEXT,
                    dayId TEXT,
                    openTaskCount INTEGER NOT NULL DEFAULT 0,
                    completedTaskCount INTEGER NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: """
                INSERT INTO blocks_new (
                    id, path, title, content, createdAt, modifiedAt, tagId, dayId, openTaskCount, completedTaskCount
                )
                SELECT
                    id, path, title, content, createdAt, modifiedAt, tagId, dayId, openTaskCount, completedTaskCount
                FROM blocks
            """)
            try db.execute(sql: "DROP TABLE blocks")
            try db.execute(sql: "ALTER TABLE blocks_new RENAME TO blocks")

            try db.execute(sql: "DELETE FROM blocks_fts")
            try db.execute(sql: """
                INSERT INTO blocks_fts (blockId, title, content)
                SELECT id, title, content FROM blocks
            """)
        }
        migrator.registerMigration("addBlockTypeAndStatus") { db in
            try db.execute(sql: "ALTER TABLE blocks ADD COLUMN type TEXT NOT NULL DEFAULT 'fleeting'")
            try db.execute(sql: "ALTER TABLE blocks ADD COLUMN status TEXT")

            let rows = try Row.fetchAll(db, sql: "SELECT id, content FROM blocks")
            for row in rows {
                let id: String = row["id"]
                let content: String = row["content"]
                let parsed = MarkdownConverter.shared.parse(content)
                let type = MarkdownConverter.normalizedType(parsed.frontmatter["type"]).rawValue
                let status = MarkdownConverter.normalizedStatus(parsed.frontmatter["status"])
                try db.execute(
                    sql: "UPDATE blocks SET type = ?, status = ? WHERE id = ?",
                    arguments: [type, status, id]
                )
            }

            try db.execute(sql: "CREATE INDEX block_type ON blocks(type)")
            try db.execute(sql: "CREATE INDEX block_status ON blocks(status)")
        }
        migrator.registerMigration("addBlockLayer") { db in
            try db.execute(sql: "ALTER TABLE blocks ADD COLUMN layer TEXT NOT NULL DEFAULT 'user'")
            try db.execute(sql: "CREATE INDEX block_layer ON blocks(layer)")
        }
        migrator.registerMigration("addBlockIsFullWidth") { db in
            try db.execute(sql: "ALTER TABLE blocks ADD COLUMN isFullWidth INTEGER NOT NULL DEFAULT 0")
        }
        return migrator
    }

    func upsertBlock(_ entry: BlockIndexEntry) async throws {
        try await performWrite { db in
            try self.upsertBlock(entry, in: db)
        }
    }

    func removeBlock(id: String) async throws {
        try await performWrite { db in
            try db.execute(sql: "DELETE FROM block_tags WHERE blockId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM blocks_fts WHERE blockId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM blocks WHERE id = ?", arguments: [id])
        }
    }

    func repairIndex(upserts: [BlockIndexEntry], removals: [String]) async throws {
        guard !upserts.isEmpty || !removals.isEmpty else { return }
        try await performWrite { db in
            for id in removals {
                try db.execute(sql: "DELETE FROM block_tags WHERE blockId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM blocks_fts WHERE blockId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM blocks WHERE id = ?", arguments: [id])
            }
            for entry in upserts {
                try self.upsertBlock(entry, in: db)
            }
        }
    }

    func rebuildIndex(entries: [BlockIndexEntry]) async throws {
        try await performWrite { db in
            try db.execute(sql: "DELETE FROM block_tags")
            try db.execute(sql: "DELETE FROM blocks_fts")
            try db.execute(sql: "DELETE FROM blocks")
            for entry in entries {
                try self.upsertBlock(entry, in: db)
            }
        }
    }

    func blockIds(matchingTag tag: String) async throws -> [String] {
        try await performRead { db in
            try String.fetchAll(db, sql: "SELECT blockId FROM block_tags WHERE tag = ?", arguments: [tag.lowercased()])
        }
    }

    func blockIdsWithOpenTaskCheckboxes() async throws -> [String] {
        try await performRead { db in
            try String.fetchAll(db, sql: "SELECT id FROM blocks WHERE openTaskCount > 0")
        }
    }

    func blockIds(createdBetween range: ClosedRange<Date>) async throws -> [String] {
        try await performRead { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM blocks WHERE createdAt BETWEEN ? AND ?",
                arguments: [range.lowerBound, range.upperBound]
            )
        }
    }

    func searchBlockIds(matching query: String) async throws -> [String] {
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }
        return try await performRead { db in
            try String.fetchAll(
                db,
                sql: "SELECT blockId FROM blocks_fts WHERE blocks_fts MATCH ?",
                arguments: [sanitized]
            )
        }
    }

    func searchBlocksContaining(wikiLink title: String) async throws -> [BlockIndexEntry] {
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let exactPattern = "%[[" + escaped + "]]%"
        let aliasedPattern = "%[[" + escaped + "|%"
        return try await performRead { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id FROM blocks WHERE LOWER(content) LIKE LOWER(?) ESCAPE '\\' OR LOWER(content) LIKE LOWER(?) ESCAPE '\\'",
                arguments: [exactPattern, aliasedPattern]
            )
            let ids = rows.map { row -> String in row["id"] }
            guard !ids.isEmpty else { return [] }
            return try self.fetchBlocks(in: db, ids: ids)
        }
    }

    func fetchBlocks(byType type: String) async throws -> [BlockIndexEntry] {
        try await performRead { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id FROM blocks WHERE type = ? ORDER BY modifiedAt DESC",
                arguments: [type]
            )
            let ids = rows.map { row -> String in row["id"] }
            guard !ids.isEmpty else { return [] }
            let entries = try self.fetchBlocks(in: db, ids: ids)
            let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            return entries.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        }
    }

    func fetchBlocks(byStatus status: String) async throws -> [BlockIndexEntry] {
        try await performRead { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id FROM blocks WHERE status = ? ORDER BY modifiedAt DESC",
                arguments: [status]
            )
            let ids = rows.map { row -> String in row["id"] }
            guard !ids.isEmpty else { return [] }
            let entries = try self.fetchBlocks(in: db, ids: ids)
            let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            return entries.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        }
    }

    func blockIds(matchingType type: String) async throws -> [String] {
        try await performRead { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM blocks WHERE type = ? ORDER BY modifiedAt DESC",
                arguments: [type]
            )
        }
    }

    func blockIds(matchingStatus status: String) async throws -> [String] {
        try await performRead { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM blocks WHERE status = ? ORDER BY modifiedAt DESC",
                arguments: [status]
            )
        }
    }

    private func sanitizeFTSQuery(_ query: String) -> String {
        let tokens = query
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
        return tokens.joined(separator: " ")
    }

    func fetchAllBlocks() async throws -> [BlockIndexEntry] {
        try await performRead { db in
            try self.fetchBlocks(in: db, ids: nil)
        }
    }

    func upsertMetadata(
        blockId: String,
        tagId: String?,
        dayId: String?,
        type: String,
        status: String?,
        layer: String,
        isFullWidth: Bool
    ) async throws {
        try await performWrite { db in
            try db.execute(
                sql: """
                UPDATE blocks
                SET tagId = ?, dayId = ?, type = ?, status = ?, layer = ?, isFullWidth = ?
                WHERE id = ?
                """,
                arguments: [tagId, dayId, type, status, layer, isFullWidth ? 1 : 0, blockId]
            )
        }
    }

    func fetchMetadataRow(for blockId: String) async throws -> Row? {
        try await performRead { db in
            try Row.fetchOne(
                db,
                sql: "SELECT tagId, dayId, type, status, layer, isFullWidth FROM blocks WHERE id = ?",
                arguments: [blockId]
            )
        }
    }

    func fetchAllMetadataRows() async throws -> [(String, Row)] {
        try await performRead { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, tagId, dayId, type, status, layer, isFullWidth FROM blocks"
            )
            return rows.map { row in
                let id: String = row["id"]
                return (id, row)
            }
        }
    }

    func fetchBlocks(ids: [String]) async throws -> [BlockIndexEntry] {
        guard !ids.isEmpty else { return [] }
        return try await performRead { db in
            try self.fetchBlocks(in: db, ids: ids)
        }
    }

    private func upsertBlock(_ entry: BlockIndexEntry, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO blocks (
                id, path, title, content, createdAt, modifiedAt, tagId, dayId,
                openTaskCount, completedTaskCount, type, status, layer, isFullWidth
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                path = excluded.path,
                title = excluded.title,
                content = excluded.content,
                createdAt = excluded.createdAt,
                modifiedAt = excluded.modifiedAt,
                tagId = excluded.tagId,
                dayId = excluded.dayId,
                openTaskCount = excluded.openTaskCount,
                completedTaskCount = excluded.completedTaskCount,
                type = excluded.type,
                status = excluded.status,
                layer = excluded.layer,
                isFullWidth = excluded.isFullWidth
            """,
            arguments: [
                entry.id,
                entry.path,
                entry.title,
                entry.content,
                entry.createdAt,
                entry.modifiedAt,
                entry.tagId,
                entry.dayId,
                entry.openTaskCount,
                entry.completedTaskCount,
                entry.type,
                entry.status,
                entry.layer,
                entry.isFullWidth ? 1 : 0
            ]
        )

        try db.execute(sql: "DELETE FROM block_tags WHERE blockId = ?", arguments: [entry.id])
        for tag in entry.tags {
            try db.execute(
                sql: "INSERT INTO block_tags (blockId, tag) VALUES (?, ?)",
                arguments: [entry.id, tag]
            )
        }

        try db.execute(sql: "DELETE FROM blocks_fts WHERE blockId = ?", arguments: [entry.id])
        try db.execute(
            sql: "INSERT INTO blocks_fts (blockId, title, content) VALUES (?, ?, ?)",
            arguments: [entry.id, entry.title, entry.content]
        )
    }

    private func fetchBlocks(in db: Database, ids: [String]?) throws -> [BlockIndexEntry] {
        var arguments: StatementArguments = []
        var clause = ""
        var tagClause = ""
        if let ids {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            clause = "WHERE id IN (\(placeholders))"
            tagClause = "WHERE blockId IN (\(placeholders))"
            arguments = StatementArguments(ids)
        }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, path, title, content, createdAt, modifiedAt, tagId, dayId, openTaskCount, completedTaskCount, type, status, layer, isFullWidth FROM blocks \(clause)",
            arguments: arguments
        )
        let tagRows = try Row.fetchAll(
            db,
            sql: "SELECT blockId, tag FROM block_tags \(tagClause)",
            arguments: arguments
        )
        var tagsById: [String: [String]] = [:]
        for row in tagRows {
            let blockId: String = row["blockId"]
            let tag: String = row["tag"]
            tagsById[blockId, default: []].append(tag)
        }
        return rows.compactMap { row in
            let id: String = row["id"]
            let path: String = row["path"]
            let title: String = row["title"]
            let content: String = row["content"]
            let createdAt: Date = row["createdAt"]
            let modifiedAt: Date = row["modifiedAt"]
            let tagId: String? = row["tagId"]
            let dayId: String? = row["dayId"]
            let openTaskCount: Int = row["openTaskCount"]
            let completedTaskCount: Int = row["completedTaskCount"]
            let type: String = row["type"]
            let status: String? = row["status"]
            let layer: String = row["layer"]
            let isFullWidthInt: Int = row["isFullWidth"]
            return BlockIndexEntry(
                id: id,
                path: path,
                title: title,
                content: content,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                tagId: tagId,
                dayId: dayId,
                openTaskCount: openTaskCount,
                completedTaskCount: completedTaskCount,
                tags: tagsById[id] ?? [],
                type: type,
                status: status,
                layer: layer,
                isFullWidth: isFullWidthInt != 0
            )
        }
    }


    private func performRead<T>(_ work: @escaping (Database) throws -> T) async throws -> T {
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

    private func performWrite<T>(_ work: @escaping (Database) throws -> T) async throws -> T {
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

extension DatabaseQueue {
    static func makeMemoryFallback() -> DatabaseQueue {
        for attempt in 0..<3 {
            if let q = try? DatabaseQueue() { return q }
            logger.fault("[DatabaseService] In-memory database creation failed (attempt \(attempt + 1))")
        }
        logger.fault("[DatabaseService] Giving up on in-memory database; serving an isolated empty store")
        return (try? DatabaseQueue(path: ":memory:")) ?? (try! DatabaseQueue())
    }
}
