import Foundation
import os

struct CachedTasksPayload: Codable {
    let fetchedAt: Date
    let payload: Data
}

enum TasksCache {
    private static let logger = Logger(subsystem: "com.gabrielmendonca.garime", category: "TasksCache")
    private static let fileName = "tasks-cache.json"

    static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Garime", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(fileName)
    }

    static func save(_ payload: Data, fetchedAt: Date = Date()) {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(CachedTasksPayload(fetchedAt: fetchedAt, payload: payload))
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("Failed to persist tasks cache: \(error.localizedDescription)")
        }
    }

    static func load() -> CachedTasksPayload? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedTasksPayload.self, from: data)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
