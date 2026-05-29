import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "BlockMetadataService")

@MainActor
final class BlockMetadataService {
    private let metadataURL: URL
    var blocksMetadata: [String: BlocksStore.BlockMetadata] = [:]
    nonisolated(unsafe) private let lastWriteTimeLock = NSLock()
    nonisolated(unsafe) private var _lastMetadataWriteTime: Date = .distantPast

    nonisolated func currentLastWriteTime() -> Date {
        lastWriteTimeLock.lock()
        defer { lastWriteTimeLock.unlock() }
        return _lastMetadataWriteTime
    }

    nonisolated private func setLastWriteTime(_ date: Date) {
        lastWriteTimeLock.lock()
        _lastMetadataWriteTime = date
        lastWriteTimeLock.unlock()
    }

    init(metadataURL: URL) {
        self.metadataURL = metadataURL
    }

    func loadMetadata() {
        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            blocksMetadata = try decoder.decode([String: BlocksStore.BlockMetadata].self, from: data)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            if blocksMetadata.isEmpty {
                blocksMetadata = [:]
            }
        } catch {
            logger.error("Failed to load blocks metadata: \(error.localizedDescription)")
            if blocksMetadata.isEmpty {
                blocksMetadata = [:]
            }
        }
    }

    func hydrateFromIndex(_ snapshot: [String: BlocksStore.BlockMetadata]) {
        guard !snapshot.isEmpty else { return }
        blocksMetadata = snapshot
    }

    func metadata(for blockId: String) -> BlocksStore.BlockMetadata {
        return blocksMetadata[blockId] ?? BlocksStore.BlockMetadata()
    }

    func currentMetadata(for blockId: String) -> BlocksStore.BlockMetadata? {
        return blocksMetadata[blockId]
    }

    func dayId(for blockId: String) -> String? {
        return blocksMetadata[blockId]?.dayId
    }

    func tagId(for blockId: String) -> String? {
        return blocksMetadata[blockId]?.tagId
    }

    func persistMetadata(_ metadata: BlocksStore.BlockMetadata, for blockId: String) {
        if metadata.isPersisted {
            blocksMetadata[blockId] = metadata
        } else {
            blocksMetadata.removeValue(forKey: blockId)
        }
        markMetadataDirty()
    }

    func removeMetadata(for blockId: String) {
        blocksMetadata.removeValue(forKey: blockId)
        markMetadataDirty()
    }

    func flushPendingMetadata() {
        markMetadataDirty()
    }

    func saveMetadata(completion: ((Bool) -> Void)? = nil) {
        markMetadataDirty()
        completion?(true)
    }

    private func markMetadataDirty() {
        setLastWriteTime(Date())
    }
}
