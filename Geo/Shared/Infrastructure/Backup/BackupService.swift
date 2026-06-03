import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "BackupService")

enum BackupError: Error {
    case dataDirMissing
    case exportFailed
    case invalidArchive
    case restoreFailed
}

extension BackupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .dataDirMissing:
            return "Geo data directory was not found."
        case .exportFailed:
            return "Failed to create the backup archive."
        case .invalidArchive:
            return "The selected file is not a valid Geo backup."
        case .restoreFailed:
            return "Failed to apply the backup."
        }
    }
}

struct ArchiveInfo: Equatable {
    let blockCount: Int
    let hasTasks: Bool
    let hasTags: Bool
}

final class BackupService: @unchecked Sendable {
    static let shared = BackupService()

    private let dataDirectory: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.geo.backup", qos: .userInitiated)

    private static func defaultDataDirectory(_ fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return baseURL.appendingPathComponent("Geo")
    }

    init(dataDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.dataDirectory = dataDirectory ?? Self.defaultDataDirectory(fileManager)
    }

    private var pendingMarkerURL: URL {
        dataDirectory.deletingLastPathComponent().appendingPathComponent("Geo.pending-restore.json")
    }

    func exportArchive(to destinationDir: URL, flush: (() -> Void)? = nil) throws -> URL {
        guard fileManager.fileExists(atPath: dataDirectory.path) else { throw BackupError.dataDirMissing }
        flush?()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let archiveName = "Geo-Backup-\(stamp).zip"

        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("geo-export-\(UUID().uuidString)", isDirectory: true)
        let cleanCopy = scratch.appendingPathComponent(dataDirectory.lastPathComponent, isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        try copyDataDirectory(into: cleanCopy)

        let tempZip = scratch.appendingPathComponent(archiveName)
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", cleanCopy.path, tempZip.path])
        guard fileManager.fileExists(atPath: tempZip.path) else { throw BackupError.exportFailed }

        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let finalURL = destinationDir.appendingPathComponent(archiveName)
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: tempZip, to: finalURL)
        return finalURL
    }

    func validateArchive(at url: URL) throws -> ArchiveInfo {
        let unpacked = try unpack(url)
        defer { try? fileManager.removeItem(at: unpacked.parent) }
        return try inspect(unpacked.root)
    }

    func stageRestore(from archiveURL: URL) throws {
        let unpacked = try unpack(archiveURL)
        _ = try inspect(unpacked.root)

        let stamp = Int(Date().timeIntervalSince1970)
        let stagingDir = dataDirectory.deletingLastPathComponent()
            .appendingPathComponent("Geo.restore-staging-\(stamp)", isDirectory: true)
        if fileManager.fileExists(atPath: stagingDir.path) {
            try fileManager.removeItem(at: stagingDir)
        }
        try fileManager.moveItem(at: unpacked.root, to: stagingDir)
        try? fileManager.removeItem(at: unpacked.parent)

        let marker = PendingRestore(stagingPath: stagingDir.path, archiveName: archiveURL.lastPathComponent, timestamp: stamp)
        let data = try JSONEncoder().encode(marker)
        try data.write(to: pendingMarkerURL, options: .atomic)
    }

    @discardableResult
    func applyPendingRestoreIfNeeded() -> Bool {
        guard let data = try? Data(contentsOf: pendingMarkerURL),
              let marker = try? JSONDecoder().decode(PendingRestore.self, from: data) else {
            return false
        }
        let stagingDir = URL(fileURLWithPath: marker.stagingPath)
        guard fileManager.fileExists(atPath: stagingDir.path) else {
            try? fileManager.removeItem(at: pendingMarkerURL)
            return false
        }

        let snapshotDir = dataDirectory.deletingLastPathComponent()
            .appendingPathComponent("Geo.pre-restore-\(marker.timestamp)", isDirectory: true)
        let liveExists = fileManager.fileExists(atPath: dataDirectory.path)

        do {
            if liveExists {
                if fileManager.fileExists(atPath: snapshotDir.path) {
                    try fileManager.removeItem(at: snapshotDir)
                }
                try fileManager.moveItem(at: dataDirectory, to: snapshotDir)
            }
            try fileManager.moveItem(at: stagingDir, to: dataDirectory)
            try? fileManager.removeItem(at: pendingMarkerURL)
            logger.info("backup: applied pending restore from \(marker.archiveName, privacy: .public)")
            return true
        } catch {
            logger.error("backup: restore apply failed: \(error.localizedDescription, privacy: .public)")
            if !fileManager.fileExists(atPath: dataDirectory.path),
               fileManager.fileExists(atPath: snapshotDir.path) {
                try? fileManager.moveItem(at: snapshotDir, to: dataDirectory)
            }
            return false
        }
    }

    private func copyDataDirectory(into destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: [.isRegularFileKey])
        for entry in entries {
            let name = entry.lastPathComponent
            if name == ".DS_Store" { continue }
            let values = try? entry.resourceValues(forKeys: [.fileResourceTypeKey])
            if values?.fileResourceType == .socket { continue }
            try fileManager.copyItem(at: entry, to: destination.appendingPathComponent(name))
        }
    }

    private func unpack(_ archiveURL: URL) throws -> (root: URL, parent: URL) {
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("geo-restore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            try runDitto(["-x", "-k", archiveURL.path, scratch.path])
        } catch {
            try? fileManager.removeItem(at: scratch)
            throw BackupError.invalidArchive
        }
        let root = scratch.appendingPathComponent("Geo", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else {
            try? fileManager.removeItem(at: scratch)
            throw BackupError.invalidArchive
        }
        return (root, scratch)
    }

    private func inspect(_ root: URL) throws -> ArchiveInfo {
        let blocksDir = root.appendingPathComponent("Blocks", isDirectory: true)
        let sqlite = root.appendingPathComponent("Index/blocks.sqlite")
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: blocksDir.path, isDirectory: &isDir), isDir.boolValue,
              fileManager.fileExists(atPath: sqlite.path) else {
            throw BackupError.invalidArchive
        }
        var blockCount = 0
        if let enumerator = fileManager.enumerator(at: blocksDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                blockCount += 1
            }
        }
        let hasTasks = fileManager.fileExists(atPath: root.appendingPathComponent("Tasks").path)
        let hasTags = fileManager.fileExists(atPath: root.appendingPathComponent("tags.json").path)
        return ArchiveInfo(blockCount: blockCount, hasTasks: hasTasks, hasTags: hasTags)
    }

    private func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            logger.error("backup: ditto failed (\(process.terminationStatus)): \(message, privacy: .public)")
            throw BackupError.exportFailed
        }
    }
}

private struct PendingRestore: Codable {
    let stagingPath: String
    let archiveName: String
    let timestamp: Int
}
