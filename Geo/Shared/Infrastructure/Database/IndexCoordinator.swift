import Foundation
import GRDB
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "IndexCoordinator")

struct IntegrityReport: Equatable {
    let missingFromIndex: [String]
    let orphanedInIndex: [String]
    let metadataDrift: [String]

    var isClean: Bool { missingFromIndex.isEmpty && orphanedInIndex.isEmpty && metadataDrift.isEmpty }
}

final class IndexCoordinator {
    static let shared = IndexCoordinator()

    private let database: DatabaseService
    private let indexer: MarkdownIndexingService

    init(database: DatabaseService = .shared, indexer: MarkdownIndexingService = .shared) {
        self.database = database
        self.indexer = indexer
    }

    func rebuildIndex(blocks: [BlocksStore.Block]) async {
        let entries = blocks.map { entry(for: $0) }
        do {
            try await database.rebuildIndex(entries: entries)
        } catch {
            logger.error("rebuildIndex failed: \(error)")
        }
    }

    func index(block: BlocksStore.Block) async {
        let entry = entry(for: block)
        do {
            try await database.upsertBlock(entry)
        } catch {
            logger.error("index(block:) failed for \(block.id): \(error)")
        }
    }

    func index(block: BlocksStore.Block, document: MarkdownDocument) async {
        let entry = entry(for: block, document: document)
        do {
            try await database.upsertBlock(entry)
        } catch {
            logger.error("index(block:document:) failed for \(block.id): \(error)")
        }
    }

    func remove(blockId: String) async {
        do {
            try await database.removeBlock(id: blockId)
        } catch {
            logger.error("remove(blockId:) failed for \(blockId): \(error)")
        }
    }

    func blockIds(matchingTag tag: String) async -> [String] {
        do {
            return try await database.blockIds(matchingTag: tag)
        } catch {
            logger.error("blockIds(matchingTag:) failed: \(error)")
            return []
        }
    }

    func blockIds(matchingDay dayId: String) async -> [String] {
        do {
            return try await database.blockIds(matchingDay: dayId)
        } catch {
            logger.error("blockIds(matchingDay:) failed: \(error)")
            return []
        }
    }

    func dayLinkMap() async -> [String: [String]] {
        let entries = await fetchAllBlocks()
        var map: [String: [String]] = [:]
        for entry in entries {
            for dayId in entry.dayIds {
                map[dayId, default: []].append(entry.id)
            }
        }
        return map
    }

    func blockId(forAltId altId: String) async -> String? {
        do {
            return try await database.blockId(forAltId: altId)
        } catch {
            logger.error("blockId(forAltId:) failed: \(error)")
            return nil
        }
    }

    func blockIdsWithOpenTaskCheckboxes() async -> [String] {
        do {
            return try await database.blockIdsWithOpenTaskCheckboxes()
        } catch {
            logger.error("blockIdsWithOpenTaskCheckboxes() failed: \(error)")
            return []
        }
    }

    func blockIds(createdBetween range: ClosedRange<Date>) async -> [String] {
        do {
            return try await database.blockIds(createdBetween: range)
        } catch {
            logger.error("blockIds(createdBetween:) failed: \(error)")
            return []
        }
    }

    func searchBlockIds(matching query: String) async -> [String] {
        do {
            return try await database.searchBlockIds(matching: query)
        } catch {
            logger.error("searchBlockIds(matching:) failed for query '\(query)': \(error)")
            return []
        }
    }

    func fetchAllBlocks() async -> [BlockIndexEntry] {
        do {
            return try await database.fetchAllBlocks()
        } catch {
            logger.error("fetchAllBlocks() failed: \(error)")
            return []
        }
    }

    func findBacklinks(for title: String) async -> [BlockIndexEntry] {
        let normalized = WikiTitleNormalizer.normalize(title)
        guard !normalized.isEmpty else { return [] }
        do {
            return try await database.searchBlocksContaining(wikiLink: normalized)
        } catch {
            logger.error("findBacklinks(for:) failed for title '\(title)': \(error)")
            return []
        }
    }

    func fetchBlocks(ids: [String]) async -> [BlockIndexEntry] {
        do {
            return try await database.fetchBlocks(ids: ids)
        } catch {
            logger.error("fetchBlocks(ids:) failed: \(error)")
            return []
        }
    }

    func fetchBlocks(byType type: String) async -> [BlockIndexEntry] {
        do {
            return try await database.fetchBlocks(byType: type)
        } catch {
            logger.error("fetchBlocks(byType:) failed: \(error)")
            return []
        }
    }

    func fetchBlocks(byStatus status: String) async -> [BlockIndexEntry] {
        do {
            return try await database.fetchBlocks(byStatus: status)
        } catch {
            logger.error("fetchBlocks(byStatus:) failed: \(error)")
            return []
        }
    }

    func blockIds(matchingType type: String) async -> [String] {
        do {
            return try await database.blockIds(matchingType: type)
        } catch {
            logger.error("blockIds(matchingType:) failed: \(error)")
            return []
        }
    }

    func blockIds(matchingStatus status: String) async -> [String] {
        do {
            return try await database.blockIds(matchingStatus: status)
        } catch {
            logger.error("blockIds(matchingStatus:) failed: \(error)")
            return []
        }
    }

    func verifyIntegrity(
        fileService: BlockFileService,
        metadataIds: Set<String>? = nil
    ) async -> IntegrityReport {
        let diskIds = enumerateDiskIds(in: fileService)
        let indexIds = Set((await fetchAllBlocks()).map { $0.id })

        let missingFromIndex = Array(diskIds.subtracting(indexIds)).sorted()
        let orphanedInIndex = Array(indexIds.subtracting(diskIds)).sorted()
        let metadataDrift: [String]
        if let metadataIds {
            metadataDrift = Array(metadataIds.subtracting(diskIds)).sorted()
        } else {
            metadataDrift = []
        }
        return IntegrityReport(
            missingFromIndex: missingFromIndex,
            orphanedInIndex: orphanedInIndex,
            metadataDrift: metadataDrift
        )
    }

    func repairIntegrity(
        fileService: BlockFileService,
        metadata: [String: BlocksStore.BlockMetadata],
        converter: MarkdownConverter = .shared
    ) async {
        let metadataIds = Set(metadata.keys)
        let report = await verifyIntegrity(fileService: fileService, metadataIds: metadataIds)

        // Re-derive block_days/block_tags COMPLETELY from file content on launch: any block whose
        // file content differs from the cached `blocks.content` is re-extracted, not just blocks
        // that are wholly missing. This closes the "stale until per-file re-edit" gap where a bulk
        // migration inlines [[date]]/tags into files but the index keeps pre-edit derived rows.
        let cachedById = Dictionary(
            (await fetchAllBlocks()).map { ($0.id, $0.content) },
            uniquingKeysWith: { first, _ in first }
        )
        let missingSet = Set(report.missingFromIndex)
        let allBlocks = await fileService.loadBlocksFromFiles(metadata: metadata, converter: converter)
        let drifted = allBlocks.filter { block in
            missingSet.contains(block.id) || cachedById[block.id] != block.markdown
        }
        let upserts = drifted.map { entry(for: $0) }

        guard !upserts.isEmpty || !report.orphanedInIndex.isEmpty else {
            logger.debug("repairIntegrity: index in sync with disk")
            return
        }
        do {
            try await database.repairIndex(upserts: upserts, removals: report.orphanedInIndex)
            logger.info("repairIntegrity: reupserted=\(upserts.count) removed=\(report.orphanedInIndex.count) metadataDrift=\(report.metadataDrift.count)")
        } catch {
            logger.error("repairIntegrity batch failed: \(error.localizedDescription)")
        }
    }

    private func enumerateDiskIds(in fileService: BlockFileService) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: fileService.blocksDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            logger.error("enumerateDiskIds failed to create enumerator")
            return []
        }
        var ids = Set<String>()
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            let rel = fileService.relativeId(for: url)
            if rel.hasPrefix("Attachments/") { continue }
            ids.insert(rel)
        }
        return ids
    }

    private func entry(for block: BlocksStore.Block) -> BlockIndexEntry {
        let index = indexer.extract(from: block.markdown)
        let type = block.metadata.type.rawValue
        let status = block.metadata.status
        let layer = block.metadata.layer.rawValue
        return BlockIndexEntry(
            id: block.id,
            path: block.url.path,
            title: block.title,
            content: block.markdown,
            createdAt: block.date,
            modifiedAt: block.lastEdited,
            dayId: block.metadata.dayId,
            openTaskCount: index.openTaskCount,
            completedTaskCount: index.completedTaskCount,
            tags: index.tags,
            type: type,
            status: status,
            layer: layer,
            isFullWidth: block.metadata.isFullWidth,
            dayIds: index.dayIds,
            altId: index.frontmatterId
        )
    }

    private func entry(for block: BlocksStore.Block, document: MarkdownDocument) -> BlockIndexEntry {
        let index = indexer.extract(from: document)
        let type = block.metadata.type.rawValue
        let status = block.metadata.status
        let layer = MarkdownConverter.normalizedLayer(document.frontmatter["layer"])?.rawValue ?? block.metadata.layer.rawValue
        return BlockIndexEntry(
            id: block.id,
            path: block.url.path,
            title: block.title,
            content: block.markdown,
            createdAt: block.date,
            modifiedAt: block.lastEdited,
            dayId: block.metadata.dayId,
            openTaskCount: index.openTaskCount,
            completedTaskCount: index.completedTaskCount,
            tags: index.tags,
            type: type,
            status: status,
            layer: layer,
            isFullWidth: block.metadata.isFullWidth,
            dayIds: index.dayIds,
            altId: index.frontmatterId
        )
    }

    func fetchMetadata(for blockId: String) async -> BlocksStore.BlockMetadata? {
        do {
            guard let row = try await database.fetchMetadataRow(for: blockId) else { return nil }
            return Self.metadata(from: row)
        } catch {
            logger.error("fetchMetadata(for:) failed for \(blockId): \(error)")
            return nil
        }
    }

    func fetchAllMetadata() async -> [String: BlocksStore.BlockMetadata] {
        do {
            let rows = try await database.fetchAllMetadataRows()
            var result: [String: BlocksStore.BlockMetadata] = [:]
            result.reserveCapacity(rows.count)
            for (id, row) in rows {
                let meta = Self.metadata(from: row)
                if meta.isPersisted {
                    result[id] = meta
                }
            }
            return result
        } catch {
            logger.error("fetchAllMetadata() failed: \(error)")
            return [:]
        }
    }

    private static func metadata(from row: Row) -> BlocksStore.BlockMetadata {
        let dayId: String? = row["dayId"]
        let typeRaw: String? = row["type"]
        let status: String? = row["status"]
        let layerRaw: String? = row["layer"]
        let isFullWidthInt: Int? = row["isFullWidth"]
        let type = BlockType(rawValue: typeRaw ?? "") ?? .fleeting
        let layer = BlockLayer(rawValue: layerRaw ?? "") ?? .default
        return BlocksStore.BlockMetadata(
            dayId: dayId,
            isFullWidth: (isFullWidthInt ?? 0) != 0,
            status: status,
            type: type,
            layer: layer
        )
    }

}
