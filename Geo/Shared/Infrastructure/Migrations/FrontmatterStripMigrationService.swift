import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "FrontmatterStripMigration")

final class FrontmatterStripMigrationService: @unchecked Sendable {
    static let shared = FrontmatterStripMigrationService()

    private let userDefaultsKey = "geo.migration.frontmatterStripped.v1"
    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    init(userDefaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    func runIfNeeded() async {
        guard !userDefaults.bool(forKey: userDefaultsKey) else { return }
        do {
            try await migrate()
            userDefaults.set(true, forKey: userDefaultsKey)
        } catch {
            logger.error("Frontmatter strip migration failed: \(error.localizedDescription)")
        }
    }

    private func migrate() async throws {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let blocksDirectory = baseURL.appendingPathComponent("Geo/Blocks", isDirectory: true)
        let metadataURL = blocksDirectory.appendingPathComponent(".blocks-metadata.json")

        guard fileManager.fileExists(atPath: blocksDirectory.path) else { return }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: blocksDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            logger.error("Failed to enumerate blocks directory: \(error.localizedDescription)")
            return
        }

        let mdFiles = files.filter { $0.pathExtension.lowercased() == "md" }
        guard !mdFiles.isEmpty else { return }

        var sidecar = loadSidecar(at: metadataURL)
        var sidecarMutated = false
        let converter = MarkdownConverter.shared

        for url in mdFiles {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let document = converter.parse(content)
            guard !document.frontmatter.isEmpty else { continue }

            let typeRaw = MarkdownConverter.normalizedType(document.frontmatter["type"]).rawValue
            let status = MarkdownConverter.normalizedStatus(document.frontmatter["status"])

            let blockId = url.lastPathComponent
            var existing = sidecar[blockId] ?? BlocksStore.BlockMetadata()
            var existingChanged = false

            if existing.type == .fleeting, typeRaw != "fleeting", let parsedType = BlockType(rawValue: typeRaw) {
                existing.type = parsedType
                existingChanged = true
            }

            if existing.status == nil, let status, !status.isEmpty {
                existing.status = status
                existingChanged = true
            }

            if existingChanged {
                sidecar[blockId] = existing
                sidecarMutated = true
            }

            let cleanedBody = String(document.body.drop { $0 == "\n" || $0 == "\r" })

            do {
                try cleanedBody.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                logger.error("Failed to rewrite block \(blockId): \(error.localizedDescription)")
                continue
            }
        }

        if sidecarMutated {
            saveSidecar(sidecar, to: metadataURL)
        }
    }

    private func loadSidecar(at url: URL) -> [String: BlocksStore.BlockMetadata] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: BlocksStore.BlockMetadata].self, from: data)) ?? [:]
    }

    private func saveSidecar(_ metadata: [String: BlocksStore.BlockMetadata], to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metadata)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to write sidecar metadata: \(error.localizedDescription)")
        }
    }
}
