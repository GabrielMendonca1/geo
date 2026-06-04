import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "BlockMetadataService")

/// In-memory metadata cache hydrated from `Index/blocks.sqlite` (the sole rebuildable cache).
///
/// The legacy `.blocks-metadata.json` sidecar was retired in Phase 0 (SQLite is authoritative);
/// the disk read/write paths have been removed. This service now only mirrors the SQLite-derived
/// metadata in RAM as a fallback for blocks whose properties are not yet inlined into frontmatter.
@MainActor
final class BlockMetadataService {
    var blocksMetadata: [String: BlocksStore.BlockMetadata] = [:]

    init() {}

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

    func persistMetadata(_ metadata: BlocksStore.BlockMetadata, for blockId: String) {
        if metadata.isPersisted {
            blocksMetadata[blockId] = metadata
        } else {
            blocksMetadata.removeValue(forKey: blockId)
        }
    }

    func removeMetadata(for blockId: String) {
        blocksMetadata.removeValue(forKey: blockId)
    }

    func flushPendingMetadata() {}
}
