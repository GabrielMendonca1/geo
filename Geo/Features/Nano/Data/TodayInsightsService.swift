import Foundation
import GRDB

@MainActor
final class TodayInsightsService: ObservableObject {
    struct ChannelCount: Equatable { let kind: String; let count: Int }
    struct LastReply: Equatable { let kind: String; let ts: Date; let text: String }

    @Published private(set) var totalToday: Int = 0
    @Published private(set) var perChannel: [ChannelCount] = []
    @Published private(set) var lastReply: LastReply?
    @Published private(set) var todayLabels: [String] = []

    private var db: DatabaseQueue?
    private var refreshTask: Task<Void, Never>?
    private let dbQueue = DispatchQueue(label: "ai.geo.today.insights", qos: .userInitiated)

    private var dbPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".hermes/state.db").path
    }

    func start() {
        guard db == nil else { return }
        openDb()
        refresh()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        db = nil
    }

    private func openDb() {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            var config = Configuration()
            config.readonly = true
            db = try DatabaseQueue(path: dbPath, configuration: config)
        } catch {
            db = nil
        }
    }

    func refresh() {
        if db == nil { openDb() }
        guard let db else { return }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let startOfDaySec = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970

            do {
                let (perChannel, lastReply) = try await Self.query(db: db, startOfDaySec: startOfDaySec)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.perChannel = perChannel
                    self.totalToday = perChannel.reduce(0) { $0 + $1.count }
                    self.lastReply = lastReply
                    self.todayLabels = self.deriveLabels(from: perChannel)
                }
            } catch {
            }
        }
    }

    nonisolated private static func query(
        db: DatabaseQueue,
        startOfDaySec: Double
    ) async throws -> ([ChannelCount], LastReply?) {
        try await Task.detached(priority: .userInitiated) {
            try db.read { d in
                let rows = try Row.fetchAll(d, sql: """
                    SELECT s.source AS kind, COUNT(*) AS n
                    FROM messages m
                    JOIN sessions s ON s.id = m.session_id
                    WHERE m.timestamp >= ?
                      AND m.role = 'user'
                    GROUP BY s.source
                    ORDER BY n DESC
                """, arguments: [startOfDaySec])

                let counts: [ChannelCount] = rows.map { r in
                    ChannelCount(kind: r["kind"] ?? "unknown", count: r["n"] ?? 0)
                }

                let lastRow = try Row.fetchOne(d, sql: """
                    SELECT s.source AS kind, m.content AS content, m.timestamp AS ts
                    FROM messages m
                    JOIN sessions s ON s.id = m.session_id
                    WHERE m.role = 'assistant'
                    ORDER BY m.timestamp DESC
                    LIMIT 1
                """)
                var last: LastReply? = nil
                if let r = lastRow {
                    let kind: String = r["kind"] ?? "unknown"
                    let content: String = r["content"] ?? ""
                    let ts: Double = r["ts"] ?? 0
                    last = LastReply(
                        kind: kind,
                        ts: Date(timeIntervalSince1970: ts),
                        text: extractText(content)
                    )
                }
                return (counts, last)
            }
        }.value
    }

    private func deriveLabels(from perChannel: [ChannelCount]) -> [String] {
        var out: [String] = []
        let total = perChannel.reduce(0) { $0 + $1.count }
        if total == 0 { return out }
        if let top = perChannel.first {
            out.append("most active · \(top.kind)")
        }
        if total >= 10 { out.append("busy day") }
        else if total >= 3 { out.append("steady") }
        else { out.append("quiet morning") }
        return out
    }

    nonisolated private static func extractText(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { return json }
        return text
    }
}
