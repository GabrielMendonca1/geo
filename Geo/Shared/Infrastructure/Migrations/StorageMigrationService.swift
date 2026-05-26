import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "StorageMigration")

final class StorageMigrationService {
    static let shared = StorageMigrationService()

    private let userDefaults = UserDefaults.standard
    private let migrationKey = "StorageMigrationV1Complete"
    private let fileManager = FileManager.default

    private init() {}

    func migrateIfNeeded(blocksDirectory: URL, metadataURL: URL) {
        guard !userDefaults.bool(forKey: migrationKey) else { return }
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let legacyURL = baseURL.appendingPathComponent("Geo/blocks.json")
        guard fileManager.fileExists(atPath: legacyURL.path) else {
            userDefaults.set(true, forKey: migrationKey)
            return
        }
        do {
            let data = try Data(contentsOf: legacyURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let legacyBlocks = try decoder.decode([LegacyBlockRecord].self, from: data)
            
            try? fileManager.createDirectory(at: blocksDirectory, withIntermediateDirectories: true)
            
            var updatedMetadata = loadMetadata(from: metadataURL)
            
            for block in legacyBlocks {
                let baseName = block.id.isEmpty ? UUID().uuidString : block.id
                let filename = baseName.hasSuffix(".md") ? baseName : "\(baseName).md"
                let fileURL = blocksDirectory.appendingPathComponent(filename)
                
                let rawBody = block.markdown.isEmpty
                    ? (block.title.isEmpty ? "" : "# \(block.title)\n")
                    : block.markdown
                
                if let metadata = block.metadata {
                    updatedMetadata[filename] = metadata
                }

                try rawBody.write(to: fileURL, atomically: true, encoding: .utf8)
                
                try? fileManager.setAttributes(
                    [
                        .creationDate: block.createdAt,
                        .modificationDate: block.lastEdited
                    ],
                    ofItemAtPath: fileURL.path
                )
            }
            
            saveMetadata(updatedMetadata, to: metadataURL)
            
            let backupURL = legacyURL.appendingPathExtension("backup")
            try? fileManager.moveItem(at: legacyURL, to: backupURL)
            userDefaults.set(true, forKey: migrationKey)
        } catch {
            logger.error("Storage migration failed: \(error.localizedDescription)")
        }
    }

    private func loadMetadata(from url: URL) -> [String: BlocksStore.BlockMetadata] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: BlocksStore.BlockMetadata].self, from: data)) ?? [:]
    }

    private func saveMetadata(_ metadata: [String: BlocksStore.BlockMetadata], to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metadata)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save metadata during storage migration: \(error.localizedDescription)")
        }
    }
}

private struct LegacyBlockRecord: Codable {
    let id: String
    let title: String
    let markdown: String
    let createdAt: Date
    let lastEdited: Date
    let metadata: BlocksStore.BlockMetadata?
}
