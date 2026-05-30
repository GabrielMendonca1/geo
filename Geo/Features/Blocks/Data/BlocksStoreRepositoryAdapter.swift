import Foundation
import Combine

protocol BlocksStoreAccess: Sendable {
    func observeBlocks() -> AsyncStream<[BlocksStore.Block]>
    func searchBlocks(matching query: String) async -> [BlocksStore.Block]
    func allBlocks() async -> [BlocksStore.Block]
    func createBlock(title: String, markdown: String) async -> BlocksStore.Block?
    func createBlock(title: String, markdown: String, folder: String?) async -> BlocksStore.Block?
    func moveBlock(id: String, toFolder folder: String?) async -> BlocksStore.Block?
    func createFolder(_ folder: String) async
    func folderPaths() async -> [String]
    func updateBlock(id: String, markdown: String) async -> Bool
    func deleteBlock(id: String) async -> Bool
    func setTag(_ tagId: String?, for blockId: String) async -> Bool
    func setFullWidth(_ isFullWidth: Bool, for blockId: String) async -> Bool
    func setLayer(_ layer: BlockLayer, for blockId: String) async -> Bool
    func setType(_ type: BlockType, for blockId: String) async -> Bool
    func setStatus(_ status: String?, for blockId: String) async -> Bool
    func checkboxes(in blockId: String) async -> [BlockCheckbox]
    func toggleCheckbox(in blockId: String, lineNumber: Int) async throws
    func mutateFrontmatter(blockId: String, merge: [String: AnyCodableValue]) async throws -> Int
    @MainActor func updateBlockAndFlush(id: String, markdown: String) -> Bool
}

extension BlocksStoreAccess {
    func createBlock(title: String, markdown: String, folder: String?) async -> BlocksStore.Block? {
        await createBlock(title: title, markdown: markdown)
    }
    func moveBlock(id: String, toFolder folder: String?) async -> BlocksStore.Block? { nil }
    func createFolder(_ folder: String) async {}
    func folderPaths() async -> [String] { [] }
}

private final class BlocksObservationBox: @unchecked Sendable {
    var cancellable: AnyCancellable?
}

private struct BlockFingerprint: Equatable {
    let id: String
    let title: String
    let lastEdited: Date
    let tagId: String?
}

final class LiveBlocksStoreAccess: BlocksStoreAccess, @unchecked Sendable {
    private let blocksStore: BlocksStore

    init(blocksStore: BlocksStore) {
        self.blocksStore = blocksStore
    }

    func observeBlocks() -> AsyncStream<[BlocksStore.Block]> {
        AsyncStream { continuation in
            let box = BlocksObservationBox()
            let setupTask = Task { @MainActor [blocksStore] in
                continuation.yield(blocksStore.blocks)
                var lastFingerprint = blocksStore.blocks.map { BlockFingerprint(id: $0.id, title: $0.title, lastEdited: $0.lastEdited, tagId: $0.tagId) }
                box.cancellable = blocksStore.$blocks
                    .dropFirst()
                    .sink { blocks in
                        let newFingerprint = blocks.map { BlockFingerprint(id: $0.id, title: $0.title, lastEdited: $0.lastEdited, tagId: $0.tagId) }
                        if newFingerprint != lastFingerprint {
                            lastFingerprint = newFingerprint
                            continuation.yield(blocks)
                        }
                    }
            }

            continuation.onTermination = { @Sendable _ in
                setupTask.cancel()
                Task { @MainActor in
                    box.cancellable?.cancel()
                    box.cancellable = nil
                }
            }
        }
    }

    func allBlocks() async -> [BlocksStore.Block] {
        await MainActor.run {
            blocksStore.blocks
        }
    }

    func searchBlocks(matching query: String) async -> [BlocksStore.Block] {
        await Task(operation: { @MainActor in
            await blocksStore.searchBlocks(matching: query)
        }).value
    }

    func createBlock(title: String, markdown: String) async -> BlocksStore.Block? {
        await Task(operation: { @MainActor in
            await blocksStore.createBlock(title: title, markdown: markdown)
        }).value
    }

    func createBlock(title: String, markdown: String, folder: String?) async -> BlocksStore.Block? {
        await Task(operation: { @MainActor in
            await blocksStore.createBlock(title: title, markdown: markdown, folder: folder)
        }).value
    }

    func moveBlock(id: String, toFolder folder: String?) async -> BlocksStore.Block? {
        await Task(operation: { @MainActor in
            await blocksStore.moveBlock(id, toFolder: folder)
        }).value
    }

    func createFolder(_ folder: String) async {
        await MainActor.run {
            blocksStore.createFolder(folder)
        }
    }

    func folderPaths() async -> [String] {
        await MainActor.run {
            blocksStore.folderPaths()
        }
    }

    func updateBlock(id: String, markdown: String) async -> Bool {
        await Task(operation: { @MainActor in
            guard let block = blocksStore.blocks.first(where: { $0.id == id }) else {
                return false
            }
            return await blocksStore.updateBlock(block, newMarkdown: markdown)
        }).value
    }

    func deleteBlock(id: String) async -> Bool {
        await Task(operation: { @MainActor in
            guard let block = blocksStore.blocks.first(where: { $0.id == id }) else {
                return false
            }
            return await blocksStore.deleteBlock(block)
        }).value
    }

    func setTag(_ tagId: String?, for blockId: String) async -> Bool {
        await MainActor.run {
            guard blocksStore.blocks.contains(where: { $0.id == blockId }) else {
                return false
            }
            blocksStore.setTag(tagId, for: blockId)
            return true
        }
    }

    func setFullWidth(_ isFullWidth: Bool, for blockId: String) async -> Bool {
        await MainActor.run {
            guard blocksStore.blocks.contains(where: { $0.id == blockId }) else {
                return false
            }
            blocksStore.setFullWidth(isFullWidth, for: blockId)
            return true
        }
    }

    func setLayer(_ layer: BlockLayer, for blockId: String) async -> Bool {
        await MainActor.run {
            guard blocksStore.blocks.contains(where: { $0.id == blockId }) else {
                return false
            }
            blocksStore.setLayer(layer, for: blockId)
            return true
        }
    }

    func setType(_ type: BlockType, for blockId: String) async -> Bool {
        await Task(operation: { @MainActor in
            await blocksStore.setType(type, for: blockId)
        }).value
    }

    func setStatus(_ status: String?, for blockId: String) async -> Bool {
        await Task(operation: { @MainActor in
            await blocksStore.setStatus(status, for: blockId)
        }).value
    }

    func checkboxes(in blockId: String) async -> [BlockCheckbox] {
        await MainActor.run {
            blocksStore.checkboxes(in: blockId)
        }
    }

    func toggleCheckbox(in blockId: String, lineNumber: Int) async throws {
        try await Task(operation: { @MainActor in
            try await blocksStore.toggleCheckbox(in: blockId, lineNumber: lineNumber)
        }).value
    }

    func mutateFrontmatter(blockId: String, merge: [String: AnyCodableValue]) async throws -> Int {
        try await Task(operation: { @MainActor in
            try await blocksStore.mutateFrontmatter(blockID: blockId, merge: merge)
        }).value
    }

    @MainActor
    func updateBlockAndFlush(id: String, markdown: String) -> Bool {
        blocksStore.updateBlockAndFlush(id: id, newMarkdown: markdown)
    }
}

struct BlocksStoreRepositoryAdapter: BlocksRepository, @unchecked Sendable {
    private let storeAccess: any BlocksStoreAccess

    init(blocksStore: BlocksStore) {
        self.storeAccess = LiveBlocksStoreAccess(blocksStore: blocksStore)
    }

    init(storeAccess: any BlocksStoreAccess) {
        self.storeAccess = storeAccess
    }

    func observe() -> AsyncStream<[BlockEntity]> {
        AsyncStream { continuation in
            let observeTask = Task {
                for await blocks in storeAccess.observeBlocks() {
                    if Task.isCancelled {
                        break
                    }
                    var seen = Set<String>()
                    let entities = blocks.compactMap { block -> BlockEntity? in
                        guard seen.insert(block.id).inserted else { return nil }
                        return BlockEntity(from: block)
                    }
                    continuation.yield(entities)
                }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                observeTask.cancel()
            }
        }
    }

    func list() async throws -> [BlockEntity] {
        await storeAccess.allBlocks().map(BlockEntity.init(from:))
    }

    func search(matching query: String) async throws -> [BlockEntity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RepositoryError.invalidInput
        }
        return await storeAccess.searchBlocks(matching: trimmed).map(BlockEntity.init(from:))
    }

    func create(title: String, markdown: String) async throws -> BlockEntity {
        guard let block = await storeAccess.createBlock(title: title, markdown: markdown) else {
            throw RepositoryError.invalidInput
        }
        return BlockEntity(from: block)
    }

    func update(id: String, markdown: String) async throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let updated = await storeAccess.updateBlock(id: id, markdown: markdown)
        if !updated {
            throw RepositoryError.notFound
        }
    }

    func delete(id: String) async throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let deleted = await storeAccess.deleteBlock(id: id)
        if !deleted {
            throw RepositoryError.notFound
        }
    }

    func setTag(blockId: String, tagId: String?) async throws {
        guard !blockId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let updated = await storeAccess.setTag(tagId, for: blockId)
        guard updated else {
            throw RepositoryError.notFound
        }
    }

    func setFullWidth(blockId: String, isFullWidth: Bool) async throws {
        guard !blockId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let updated = await storeAccess.setFullWidth(isFullWidth, for: blockId)
        guard updated else {
            throw RepositoryError.notFound
        }
    }

    func setLayer(blockId: String, layer: BlockLayer) async throws {
        guard !blockId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let updated = await storeAccess.setLayer(layer, for: blockId)
        guard updated else {
            throw RepositoryError.notFound
        }
    }

    func setType(blockId: String, type: BlockType) async throws {
        guard !blockId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let updated = await storeAccess.setType(type, for: blockId)
        guard updated else {
            throw RepositoryError.notFound
        }
    }

    func setStatus(blockId: String, status: String?) async throws {
        guard !blockId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }

        let updated = await storeAccess.setStatus(status, for: blockId)
        guard updated else {
            throw RepositoryError.notFound
        }
    }

    func checkboxes(in blockId: String) async -> [BlockCheckbox] {
        await storeAccess.checkboxes(in: blockId)
    }

    func toggleCheckbox(in blockId: String, lineNumber: Int) async throws {
        try await storeAccess.toggleCheckbox(in: blockId, lineNumber: lineNumber)
    }

    func mutateFrontmatter(blockId: String, merge: [String: AnyCodableValue]) async throws -> Int {
        guard !blockId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.invalidInput
        }
        return try await storeAccess.mutateFrontmatter(blockId: blockId, merge: merge)
    }

    @MainActor
    func saveSync(id: String, markdown: String) -> Bool {
        storeAccess.updateBlockAndFlush(id: id, markdown: markdown)
    }
}

extension BlockEntity {
    init(from block: BlocksStore.Block) {
        self.init(
            id: block.id,
            title: block.title,
            date: block.date,
            lastEdited: block.lastEdited,
            markdown: block.markdown,
            url: block.url,
            tagId: block.tagId,
            metadata: Metadata(dayId: block.metadata.dayId, tagId: block.metadata.tagId, isFullWidth: block.metadata.isFullWidth, status: block.metadata.status, type: block.metadata.type, layer: block.metadata.layer)
        )
    }
}

extension BlocksStore.Block {
    init(from entity: BlockEntity) {
        self.init(
            id: entity.id,
            title: entity.title,
            date: entity.date,
            lastEdited: entity.lastEdited,
            markdown: entity.markdown,
            url: entity.url,
            tagId: entity.tagId,
            metadata: BlocksStore.BlockMetadata(dayId: entity.metadata.dayId, tagId: entity.metadata.tagId, isFullWidth: entity.metadata.isFullWidth, status: entity.metadata.status, type: entity.metadata.type, layer: entity.metadata.layer)
        )
    }
}
