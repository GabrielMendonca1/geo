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
    let dayIds: [String]
    let altId: String?

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
        isFullWidth: Bool = false,
        dayIds: [String] = [],
        altId: String? = nil
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
        self.dayIds = dayIds
        self.altId = altId
    }
}

enum DatabaseSchemaProfile: Sendable {
    case personal
    case domain
}

final class DatabaseService: @unchecked Sendable {
    static let shared = DatabaseService()

    private var dbQueue: DatabaseQueue
    private let queue = DispatchQueue(label: "com.geo.database", qos: .userInitiated)

    init(databaseURL: URL? = nil, fileManager: FileManager = .default, schema: DatabaseSchemaProfile = .personal) {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        // Index/blocks.sqlite is the SOLE live, rebuildable cache (FTS + graph + tag/day maps),
        // re-derived from the .md files via FileWatcher -> BlockChangeReconciler -> rebuildIndex.
        // Orphan disk artifacts with no code references: geo-index.db (stale FTS), the 0-byte
        // Index/blocks.db, and the 0-byte geo.sqlite — clean manually, never read here.
        let resolvedURL = databaseURL
            ?? baseURL.appendingPathComponent("Geo/Index/blocks.sqlite")
        try? fileManager.createDirectory(at: resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        dbQueue = Self.openOrRecreate(at: resolvedURL, fileManager: fileManager)
        let m = Self.buildMigrator(schema: schema)
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

    private static func buildMigrator(schema: DatabaseSchemaProfile = .personal) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerPersonalMigrations(&migrator)
        if case .domain = schema {
            registerDomainMigrations(&migrator)
        }
        return migrator
    }

    private static func registerPersonalMigrations(_ migrator: inout DatabaseMigrator) {
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
        migrator.registerMigration("collapseBlockIdNFCDuplicates") { db in
            func bytesEqual(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }
            let rows = try Row.fetchAll(db, sql: "SELECT id, modifiedAt FROM blocks")
            var groups: [String: [(id: String, modifiedAt: Date)]] = [:]
            for row in rows {
                let id: String = row["id"]
                let modifiedAt: Date = row["modifiedAt"]
                let canonical = id.precomposedStringWithCanonicalMapping
                groups[canonical, default: []].append((id, modifiedAt))
            }
            for (canonical, members) in groups {
                guard members.count > 1 || !bytesEqual(members[0].id, canonical) else { continue }
                let survivor = members.first(where: { bytesEqual($0.id, canonical) })
                    ?? members.max(by: { $0.modifiedAt < $1.modifiedAt })!
                for member in members where !bytesEqual(member.id, survivor.id) {
                    try db.execute(sql: "DELETE FROM block_tags WHERE blockId = ?", arguments: [member.id])
                    try db.execute(sql: "DELETE FROM blocks_fts WHERE blockId = ?", arguments: [member.id])
                    try db.execute(sql: "DELETE FROM blocks WHERE id = ?", arguments: [member.id])
                }
                if !bytesEqual(survivor.id, canonical) {
                    try db.execute(sql: "UPDATE block_tags SET blockId = ? WHERE blockId = ?", arguments: [canonical, survivor.id])
                    try db.execute(sql: "UPDATE blocks_fts SET blockId = ? WHERE blockId = ?", arguments: [canonical, survivor.id])
                    try db.execute(sql: "UPDATE blocks SET id = ? WHERE id = ?", arguments: [canonical, survivor.id])
                }
            }
        }
        migrator.registerMigration("createBlockDaysAndAltId") { db in
            try db.create(table: "block_days") { t in
                t.column("blockId", .text).notNull()
                t.column("dayId", .text).notNull()
                t.primaryKey(["blockId", "dayId"])
            }
            try db.create(index: "block_days_day", on: "block_days", columns: ["dayId"])
            try db.execute(sql: "ALTER TABLE blocks ADD COLUMN altId TEXT")
            try db.execute(sql: "CREATE INDEX block_altId ON blocks(altId)")
        }
    }

    private static func registerDomainMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createBrainEdges") { db in
            try db.create(table: "edges") { t in
                t.column("sourceId", .text).notNull()
                t.column("targetTitle", .text).notNull()
                t.column("targetId", .text)
            }
            try db.create(index: "edges_source", on: "edges", columns: ["sourceId"])
            try db.create(index: "edges_target", on: "edges", columns: ["targetId"])
        }
        migrator.registerMigration("createBrainNodeVec") { db in
            try db.create(table: "node_vec") { t in
                t.column("blockId", .text).primaryKey()
                t.column("dims", .integer).notNull()
                t.column("embedding", .blob).notNull()
            }
        }
    }

    func upsertBlock(_ entry: BlockIndexEntry) async throws {
        try await performWrite { db in
            try self.upsertBlock(entry, in: db)
        }
    }

    func removeBlock(id: String) async throws {
        try await performWrite { db in
            try db.execute(sql: "DELETE FROM block_tags WHERE blockId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM block_days WHERE blockId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM blocks_fts WHERE blockId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM blocks WHERE id = ?", arguments: [id])
        }
    }

    func repairIndex(upserts: [BlockIndexEntry], removals: [String]) async throws {
        guard !upserts.isEmpty || !removals.isEmpty else { return }
        try await performWrite { db in
            for id in removals {
                try db.execute(sql: "DELETE FROM block_tags WHERE blockId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM block_days WHERE blockId = ?", arguments: [id])
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
            try db.execute(sql: "DELETE FROM block_days")
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

    func blockIds(matchingDay dayId: String) async throws -> [String] {
        try await performRead { db in
            try String.fetchAll(db, sql: "SELECT blockId FROM block_days WHERE dayId = ?", arguments: [dayId])
        }
    }

    func blockId(forAltId altId: String) async throws -> String? {
        try await performRead { db in
            try String.fetchOne(db, sql: "SELECT id FROM blocks WHERE altId = ? LIMIT 1", arguments: [altId])
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
                sql: "SELECT blockId FROM blocks_fts WHERE blocks_fts MATCH ? ORDER BY bm25(blocks_fts) LIMIT 25",
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
        return tokens.joined(separator: " OR ")
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

    struct BrainEdge: Sendable, Equatable {
        let sourceId: String
        let targetTitle: String
        let targetId: String?
    }

    func setEdges(forSource sourceId: String, edges: [BrainEdge]) async throws {
        try await performWrite { db in
            guard try db.tableExists("edges") else { return }
            try db.execute(sql: "DELETE FROM edges WHERE sourceId = ?", arguments: [sourceId])
            for edge in edges {
                try db.execute(
                    sql: "INSERT INTO edges (sourceId, targetTitle, targetId) VALUES (?, ?, ?)",
                    arguments: [edge.sourceId, edge.targetTitle, edge.targetId]
                )
            }
        }
    }

    func outgoingEdges(from sourceId: String) async throws -> [BrainEdge] {
        try await performRead { db in
            guard try db.tableExists("edges") else { return [] }
            let rows = try Row.fetchAll(db, sql: "SELECT sourceId, targetTitle, targetId FROM edges WHERE sourceId = ?", arguments: [sourceId])
            return rows.map { BrainEdge(sourceId: $0["sourceId"], targetTitle: $0["targetTitle"], targetId: $0["targetId"]) }
        }
    }

    func incomingEdges(to targetId: String) async throws -> [BrainEdge] {
        try await performRead { db in
            guard try db.tableExists("edges") else { return [] }
            let rows = try Row.fetchAll(db, sql: "SELECT sourceId, targetTitle, targetId FROM edges WHERE targetId = ?", arguments: [targetId])
            return rows.map { BrainEdge(sourceId: $0["sourceId"], targetTitle: $0["targetTitle"], targetId: $0["targetId"]) }
        }
    }

    func resolveEdgeTargets(title: String, toBlockId blockId: String) async throws {
        try await performWrite { db in
            guard try db.tableExists("edges") else { return }
            try db.execute(sql: "UPDATE edges SET targetId = ? WHERE targetId IS NULL AND targetTitle = ?", arguments: [blockId, title])
        }
    }

    private static func encodeVector(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }

    private static func decodeVector(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func upsertVector(blockId: String, embedding: [Float]) async throws {
        let data = Self.encodeVector(embedding)
        let dims = embedding.count
        try await performWrite { db in
            guard try db.tableExists("node_vec") else { return }
            try db.execute(
                sql: "INSERT INTO node_vec (blockId, dims, embedding) VALUES (?, ?, ?) ON CONFLICT(blockId) DO UPDATE SET dims = excluded.dims, embedding = excluded.embedding",
                arguments: [blockId, dims, data]
            )
        }
    }

    func loadAllVectors() async throws -> [(id: String, vector: [Float])] {
        try await performRead { db in
            guard try db.tableExists("node_vec") else { return [] }
            let rows = try Row.fetchAll(db, sql: "SELECT blockId, embedding FROM node_vec")
            return rows.map { row in
                let id: String = row["blockId"]
                let data: Data = row["embedding"]
                return (id, Self.decodeVector(data))
            }
        }
    }

    private func upsertBlock(_ entry: BlockIndexEntry, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO blocks (
                id, path, title, content, createdAt, modifiedAt, tagId, dayId,
                openTaskCount, completedTaskCount, type, status, layer, isFullWidth, altId
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                isFullWidth = excluded.isFullWidth,
                altId = excluded.altId
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
                entry.isFullWidth ? 1 : 0,
                entry.altId
            ]
        )

        try db.execute(sql: "DELETE FROM block_tags WHERE blockId = ?", arguments: [entry.id])
        for tag in entry.tags {
            try db.execute(
                sql: "INSERT INTO block_tags (blockId, tag) VALUES (?, ?)",
                arguments: [entry.id, tag]
            )
        }

        try db.execute(sql: "DELETE FROM block_days WHERE blockId = ?", arguments: [entry.id])
        for dayId in entry.dayIds {
            try db.execute(
                sql: "INSERT INTO block_days (blockId, dayId) VALUES (?, ?)",
                arguments: [entry.id, dayId]
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
            sql: "SELECT id, path, title, content, createdAt, modifiedAt, tagId, dayId, openTaskCount, completedTaskCount, type, status, layer, isFullWidth, altId FROM blocks \(clause)",
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
        let dayRows = try Row.fetchAll(
            db,
            sql: "SELECT blockId, dayId FROM block_days \(tagClause)",
            arguments: arguments
        )
        var daysById: [String: [String]] = [:]
        for row in dayRows {
            let blockId: String = row["blockId"]
            let dayId: String = row["dayId"]
            daysById[blockId, default: []].append(dayId)
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
            let altId: String? = row["altId"]
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
                isFullWidth: isFullWidthInt != 0,
                dayIds: daysById[id] ?? [],
                altId: altId
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
