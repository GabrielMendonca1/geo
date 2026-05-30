import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "BlocksStore")

@MainActor
class BlocksStore: ObservableObject {

    @Published private(set) var blocks: [Block] = [] {
        didSet { rebuildBlocksIndex() }
    }
    @Published private(set) var focusedBlockId: String?

    private var blocksById: [String: Int] = [:]

    private func rebuildBlocksIndex() {
        var map: [String: Int] = [:]
        map.reserveCapacity(blocks.count)
        for (i, b) in blocks.enumerated() { map[b.id] = i }
        blocksById = map
    }

    private func indexOfBlock(id: String) -> Int? {
        if let i = blocksById[id], i < blocks.count, blocks[i].id == id { return i }
        return blocks.firstIndex(where: { $0.id == id })
    }

    private func block(withId id: String) -> Block? {
        guard let i = indexOfBlock(id: id) else { return nil }
        return blocks[i]
    }

    @MainActor
    func setFocusedBlock(_ id: String?) {
        guard focusedBlockId != id else { return }
        focusedBlockId = id
    }

    struct Block: Identifiable, Hashable {
        let id: String
        let title: String
        let date: Date
        let lastEdited: Date
        let markdown: String
        let url: URL
        let tagId: String?
        let metadata: BlockMetadata
    }

    struct BlockMetadata: Codable, Hashable {
        var dayId: String?
        var tagId: String?
        var isFullWidth: Bool
        var status: String?
        var type: BlockType
        var layer: BlockLayer
        var frontmatter_version: Int

        init(
            dayId: String? = nil,
            tagId: String? = nil,
            isFullWidth: Bool = false,
            status: String? = nil,
            type: BlockType = .fleeting,
            layer: BlockLayer = .default,
            frontmatter_version: Int = 0
        ) {
            self.dayId = dayId
            self.tagId = tagId
            self.isFullWidth = isFullWidth
            self.status = status
            self.type = type
            self.layer = layer
            self.frontmatter_version = frontmatter_version
        }

        enum CodingKeys: String, CodingKey {
            case dayId, tagId, isFullWidth, status, type, layer, frontmatter_version
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            dayId = try container.decodeIfPresent(String.self, forKey: .dayId)
            tagId = try container.decodeIfPresent(String.self, forKey: .tagId)
            isFullWidth = try container.decodeIfPresent(Bool.self, forKey: .isFullWidth) ?? false
            status = try container.decodeIfPresent(String.self, forKey: .status)
            type = try container.decodeIfPresent(BlockType.self, forKey: .type) ?? .fleeting
            layer = try container.decodeIfPresent(BlockLayer.self, forKey: .layer) ?? .default
            frontmatter_version = try container.decodeIfPresent(Int.self, forKey: .frontmatter_version) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(dayId, forKey: .dayId)
            try container.encodeIfPresent(tagId, forKey: .tagId)
            if isFullWidth {
                try container.encode(true, forKey: .isFullWidth)
            }
            try container.encodeIfPresent(status, forKey: .status)
            try container.encode(type, forKey: .type)
            if layer != .default {
                try container.encode(layer, forKey: .layer)
            }
            if frontmatter_version != 0 {
                try container.encode(frontmatter_version, forKey: .frontmatter_version)
            }
        }

        var isPersisted: Bool {
            dayId != nil || tagId != nil || isFullWidth || status != nil || layer != .default || frontmatter_version != 0
        }
    }

    let fileService: BlockFileService
    let metadataService: BlockMetadataService
    let changeReconciler: BlockChangeReconciler
    private let indexCoordinator: IndexCoordinator
    private let dayManager: DayManager
    private let markdownConverter: MarkdownConverter
    private let frontmatterMutatorActor = FrontmatterMutatorActor()
    nonisolated(unsafe) private var pendingSaves: Set<Task<Void, Never>> = []
    nonisolated(unsafe) private let pendingSavesLock = NSLock()

    nonisolated private func insertPendingSave(_ task: Task<Void, Never>) {
        pendingSavesLock.lock(); defer { pendingSavesLock.unlock() }
        pendingSaves.insert(task)
    }

    nonisolated private func removePendingSave(_ task: Task<Void, Never>) {
        pendingSavesLock.lock(); defer { pendingSavesLock.unlock() }
        pendingSaves.remove(task)
    }

    nonisolated private func snapshotPendingSavesLocked() -> [Task<Void, Never>] {
        pendingSavesLock.lock(); defer { pendingSavesLock.unlock() }
        return Array(pendingSaves)
    }

    init(
        baseURL: URL? = nil,
        loadAsync: Bool = true,
        enableWatcher: Bool = true,
        indexCoordinator: IndexCoordinator = .shared,
        dayManager: DayManager,
        storageMigration: StorageMigrationService = .shared,
        markdownConverter: MarkdownConverter = .shared
    ) {
        self.indexCoordinator = indexCoordinator
        self.dayManager = dayManager
        self.markdownConverter = markdownConverter

        let fileService = BlockFileService(baseURL: baseURL, markdownConverter: markdownConverter)
        self.fileService = fileService

        let metadataURL = fileService.blocksDirectory.appendingPathComponent(".blocks-metadata.json")
        let metadataService = BlockMetadataService(metadataURL: metadataURL)
        self.metadataService = metadataService

        let reconciler = BlockChangeReconciler(
            fileService: fileService,
            metadataService: metadataService,
            indexCoordinator: indexCoordinator
        )
        self.changeReconciler = reconciler

        storageMigration.migrateIfNeeded(blocksDirectory: fileService.blocksDirectory, metadataURL: metadataURL)
        metadataService.loadMetadata()

        reconciler.onBlocksChanged = { [weak self] updatedBlocks in
            self?.blocks = updatedBlocks
        }
        reconciler.currentBlocksProvider = { [weak self] in
            self?.blocks ?? []
        }

        let startWatcher = enableWatcher
        if loadAsync {
            Task.detached(priority: .userInitiated) { [weak self, weak metadataService, indexCoordinator] in
                await self?.loadBlocks()
                let snapshot = await indexCoordinator.fetchAllMetadata()
                await MainActor.run { [weak self, weak metadataService] in
                    metadataService?.hydrateFromIndex(snapshot)
                    if startWatcher {
                        self?.changeReconciler.startWatching()
                    }
                }
            }
        } else {
            Task { [weak self, weak metadataService, indexCoordinator] in
                await self?.loadBlocks()
                let snapshot = await indexCoordinator.fetchAllMetadata()
                metadataService?.hydrateFromIndex(snapshot)
                if startWatcher {
                    self?.changeReconciler.startWatching()
                }
            }
        }
    }

    func reload() {
        Task.detached(priority: .userInitiated) {
            await self.loadBlocks()
        }
    }

    @MainActor
    @discardableResult
    func createBlock(title: String, markdown: String, folder: String? = nil) async -> Block? {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("BlocksStore", operation: "create")
        defer { PerformanceTracker.shared.endStoreOperation("BlocksStore", operation: "create", signpostID: spID, startTime: spStart) }
        let sanitized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = sanitized.isEmpty ? "Block" : sanitized

        if let folder, !folder.isEmpty { try? fileService.createFolder(folder) }
        let url = fileService.uniqueURL(forTitle: filename, inFolder: folder)

        let body = markdown.isEmpty ? (sanitized.isEmpty ? "" : "# \(sanitized)\n") : markdown

        let now = Date()
        let metadata = BlockMetadata()
        let newBlock = Block(
            id: fileService.relativeId(for: url),
            title: sanitized,
            date: now,
            lastEdited: now,
            markdown: body,
            url: url,
            tagId: metadata.tagId,
            metadata: metadata
        )

        blocks.insert(newBlock, at: 0)
        dayManager.recordBlockCreation(id: newBlock.id)
        changeReconciler.recordWrite(for: newBlock.id)

        let blockId = newBlock.id
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await self?.fileService.writeMarkdownToDisk(body, url: url)
            } catch {
                logger.error("Failed to write block to disk: \(error)")
                await MainActor.run { [weak self] in
                    self?.blocks.removeAll { $0.id == blockId }
                }
            }
        }

        Task {
            await indexCoordinator.index(block: newBlock)
        }

        return newBlock
    }

    @MainActor
    @discardableResult
    func updateBlock(_ block: Block, newMarkdown: String) async -> Bool {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("BlocksStore", operation: "update")
        defer { PerformanceTracker.shared.endStoreOperation("BlocksStore", operation: "update", signpostID: spID, startTime: spStart) }
        guard let index = self.indexOfBlock(id: block.id) else {
            return false
        }

        let currentBlock = self.blocks[index]
        let url = currentBlock.url
        let oldMarkdown = currentBlock.markdown

        do {
            try await fileService.writeMarkdownToDisk(newMarkdown, url: url)
        } catch {
            logger.error("Failed to write block \(currentBlock.id): \(error)")
            NotificationCenter.default.post(
                name: .blockWriteFailed,
                object: nil,
                userInfo: ["blockId": currentBlock.id, "error": error.localizedDescription]
            )
            return false
        }

        let interimBlock = Block(
            id: currentBlock.id,
            title: currentBlock.title,
            date: currentBlock.date,
            lastEdited: Date(),
            markdown: newMarkdown,
            url: currentBlock.url,
            tagId: currentBlock.tagId,
            metadata: currentBlock.metadata
        )
        if let liveIndex = self.indexOfBlock(id: currentBlock.id) {
            self.blocks[liveIndex] = interimBlock
        } else {
            self.blocks.append(interimBlock)
        }
        changeReconciler.recordWrite(for: interimBlock.id)

        let blockId = currentBlock.id
        let fileService = self.fileService
        let markdownConverter = self.markdownConverter
        let indexCoordinator = self.indexCoordinator

        let interimTitle = currentBlock.title
        let snapshotForIndex = interimBlock
        var task: Task<Void, Never>!
        task = Task.detached(priority: .utility) { [weak self] in
            fileService.cleanupRemovedImages(oldMarkdown: oldMarkdown, newMarkdown: newMarkdown)
            let document = markdownConverter.parse(newMarkdown)
            let newTitle = fileService.titleFromDocument(document, fallback: interimTitle, allowTodoTitle: false)
            let status = MarkdownConverter.normalizedStatus(document.frontmatter["status"])
            let type = MarkdownConverter.normalizedType(document.frontmatter["type"])
            let fmVersion = MarkdownConverter.frontmatterVersion(document.frontmatter["frontmatter_version"])

            await indexCoordinator.index(block: snapshotForIndex, document: document)

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let liveIndex = self.indexOfBlock(id: blockId),
                      self.blocks[liveIndex].markdown == newMarkdown else { return }
                let live = self.blocks[liveIndex]
                var meta = self.metadataService.currentMetadata(for: blockId) ?? live.metadata
                meta.status = status
                meta.type = type
                meta.frontmatter_version = fmVersion
                self.blocks[liveIndex] = Block(
                    id: live.id,
                    title: newTitle,
                    date: live.date,
                    lastEdited: live.lastEdited,
                    markdown: live.markdown,
                    url: live.url,
                    tagId: meta.tagId,
                    metadata: meta
                )
            }

            if let task { self?.removePendingSave(task) }
        }
        insertPendingSave(task)
        return true
    }

    func flushAll() async {
        while true {
            let snapshot = snapshotPendingSavesLocked()
            if snapshot.isEmpty { return }
            for t in snapshot {
                _ = await t.value
            }
        }
    }

    nonisolated func snapshotPendingSaves() -> [Task<Void, Never>] {
        snapshotPendingSavesLocked()
    }

    @MainActor
    @discardableResult
    func updateBlockAndFlush(id: String, newMarkdown: String) -> Bool {
        guard let index = self.indexOfBlock(id: id) else {
            return false
        }

        let currentBlock = self.blocks[index]

        do {
            try fileService.writeMarkdownSync(newMarkdown, url: currentBlock.url)
        } catch {
            logger.error("Failed to write block \(currentBlock.id): \(error)")
            NotificationCenter.default.post(
                name: .blockWriteFailed,
                object: nil,
                userInfo: ["blockId": currentBlock.id, "error": error.localizedDescription]
            )
            return false
        }

        fileService.cleanupRemovedImages(oldMarkdown: currentBlock.markdown, newMarkdown: newMarkdown)
        let document = markdownConverter.parse(newMarkdown)
        let newTitle = fileService.titleFromDocument(document, fallback: currentBlock.title, allowTodoTitle: false)

        var meta = metadataService.currentMetadata(for: currentBlock.id) ?? currentBlock.metadata
        meta.status = MarkdownConverter.normalizedStatus(document.frontmatter["status"])
        meta.type = MarkdownConverter.normalizedType(document.frontmatter["type"])
        meta.frontmatter_version = MarkdownConverter.frontmatterVersion(document.frontmatter["frontmatter_version"])
        let updatedBlock = Block(
            id: currentBlock.id,
            title: newTitle,
            date: currentBlock.date,
            lastEdited: Date(),
            markdown: newMarkdown,
            url: currentBlock.url,
            tagId: meta.tagId,
            metadata: meta
        )

        self.blocks[index] = updatedBlock
        changeReconciler.recordWrite(for: updatedBlock.id)
        flushPendingMetadata()
        Task {
            await indexCoordinator.index(block: updatedBlock, document: document)
        }
        return true
    }

    @MainActor
    @discardableResult
    func deleteBlock(_ block: Block) async -> Bool {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("BlocksStore", operation: "delete")
        defer { PerformanceTracker.shared.endStoreOperation("BlocksStore", operation: "delete", signpostID: spID, startTime: spStart) }
        do {
            try await fileService.removeMarkdownFromDisk(url: block.url)
        } catch {
            logger.error("Failed to delete block: \(error)")
            return false
        }

        fileService.deleteAttachmentsDirectory(for: block.url)

        if let index = self.indexOfBlock(id: block.id) {
            self.blocks.remove(at: index)
        }
        if focusedBlockId == block.id {
            focusedBlockId = nil
        }
        metadataService.removeMetadata(for: block.id)
        changeReconciler.recordWrite(for: block.id)
        Task {
            await indexCoordinator.remove(blockId: block.id)
        }
        return true
    }

    @MainActor
    @discardableResult
    func moveBlock(_ blockId: String, toFolder folder: String?) async -> Block? {
        guard let index = indexOfBlock(id: blockId) else { return nil }
        let block = blocks[index]
        let filename = block.url.lastPathComponent
        let destURL = fileService.folderURL(for: folder ?? "").appendingPathComponent(filename)
        let newId = fileService.relativeId(for: destURL)
        guard newId != blockId else { return block }

        do {
            try fileService.moveFile(from: block.url, to: destURL)
        } catch {
            logger.error("Failed to move block \(blockId) to \(folder ?? "root"): \(error.localizedDescription)")
            return nil
        }

        if let meta = metadataService.currentMetadata(for: blockId) {
            metadataService.persistMetadata(meta, for: newId)
            metadataService.removeMetadata(for: blockId)
        }

        let moved = Block(
            id: newId,
            title: block.title,
            date: block.date,
            lastEdited: block.lastEdited,
            markdown: block.markdown,
            url: destURL,
            tagId: block.tagId,
            metadata: block.metadata
        )
        blocks[index] = moved
        if focusedBlockId == blockId { focusedBlockId = newId }
        changeReconciler.recordWrite(for: blockId)
        changeReconciler.recordWrite(for: newId)
        Task {
            await indexCoordinator.remove(blockId: blockId)
            await indexCoordinator.index(block: moved)
        }
        return moved
    }

    func createFolder(_ folder: String) {
        try? fileService.createFolder(folder)
    }

    func folderPaths() -> [String] {
        fileService.listFolderPaths()
    }

    func dayId(for blockId: String) -> String? {
        metadataService.dayId(for: blockId)
    }

    func tagId(for blockId: String) -> String? {
        metadataService.tagId(for: blockId)
    }

    func metadata(for blockId: String) -> BlockMetadata {
        metadataService.metadata(for: blockId)
    }

    func updateBlockMetadata(for blockId: String, update: (inout BlockMetadata) -> Void) {
        var meta = metadataService.currentMetadata(for: blockId) ?? BlockMetadata()
        update(&meta)
        metadataService.persistMetadata(meta, for: blockId)

        if let index = indexOfBlock(id: blockId) {
            let block = blocks[index]
            let updatedBlock = Block(
                id: block.id,
                title: block.title,
                date: block.date,
                lastEdited: block.lastEdited,
                markdown: block.markdown,
                url: block.url,
                tagId: meta.tagId,
                metadata: meta
            )
            blocks[index] = updatedBlock
            Task {
                await indexCoordinator.index(block: updatedBlock)
            }
        }
    }

    func linkBlockToDay(_ blockId: String, dayId: String) {
        updateBlockMetadata(for: blockId) { metadata in
            metadata.dayId = dayId
        }
    }

    func setTag(_ tagId: String?, for blockId: String) {
        updateBlockMetadata(for: blockId) { metadata in
            metadata.tagId = tagId
        }
    }

    func setFullWidth(_ isFullWidth: Bool, for blockId: String) {
        updateBlockMetadata(for: blockId) { metadata in
            metadata.isFullWidth = isFullWidth
        }
    }

    func setLayer(_ layer: BlockLayer, for blockId: String) {
        updateBlockMetadata(for: blockId) { metadata in
            metadata.layer = layer
        }
    }

    @MainActor
    @discardableResult
    func setType(_ type: BlockType, for blockId: String) async -> Bool {
        guard indexOfBlock(id: blockId) != nil else { return false }
        do {
            _ = try await mutateFrontmatter(blockID: blockId, merge: ["type": .string(type.rawValue)])
            if let live = block(withId: blockId) {
                metadataService.persistMetadata(live.metadata, for: blockId)
            }
            return true
        } catch {
            logger.error("setType failed for \(blockId): \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    @discardableResult
    func setStatus(_ status: String?, for blockId: String) async -> Bool {
        guard indexOfBlock(id: blockId) != nil else { return false }
        do {
            let merge: [String: AnyCodableValue]
            if let status, !status.isEmpty {
                merge = ["status": .string(status)]
            } else {
                merge = ["status": .null]
            }
            _ = try await mutateFrontmatter(blockID: blockId, merge: merge)
            if let live = block(withId: blockId) {
                metadataService.persistMetadata(live.metadata, for: blockId)
            }
            return true
        } catch {
            logger.error("setStatus failed for \(blockId): \(error.localizedDescription)")
            return false
        }
    }

    func clearTagAssignments(for tagId: String) {
        let affectedBlockIds = metadataService.blocksMetadata
            .filter { $0.value.tagId == tagId }
            .map { $0.key }

        for blockId in affectedBlockIds {
            updateBlockMetadata(for: blockId) { metadata in
                metadata.tagId = nil
            }
        }
    }

    func blocks(matchingTag tag: String) async -> [Block] {
        let ids = await indexCoordinator.blockIds(matchingTag: tag)
        return await blocksForIds(ids)
    }

    func blocksWithOpenTaskCheckboxes() async -> [Block] {
        let ids = await indexCoordinator.blockIdsWithOpenTaskCheckboxes()
        return await blocksForIds(ids)
    }

    func blocks(createdBetween range: ClosedRange<Date>) async -> [Block] {
        let ids = await indexCoordinator.blockIds(createdBetween: range)
        return await blocksForIds(ids)
    }

    func searchBlocks(matching query: String) async -> [Block] {
        let ids = await indexCoordinator.searchBlockIds(matching: query)
        return await blocksForIds(ids)
    }

    func flushPendingMetadata() {
        metadataService.flushPendingMetadata()
    }

    private func blocksForIds(_ ids: [String]) async -> [Block] {
        guard !ids.isEmpty else { return [] }
        let entries = await indexCoordinator.fetchBlocks(ids: ids)
        let loaded = entries.map { blockFrom(entry: $0) }
        return loaded.sorted { $0.date > $1.date }
    }

    private func blockFrom(entry: BlockIndexEntry) -> Block {
        let meta = metadataFor(entry: entry)
        let url = URL(fileURLWithPath: entry.path)
        return Block(
            id: entry.id,
            title: entry.title,
            date: entry.createdAt,
            lastEdited: entry.modifiedAt,
            markdown: entry.content,
            url: url,
            tagId: meta.tagId,
            metadata: meta
        )
    }

    private func metadataFor(entry: BlockIndexEntry) -> BlockMetadata {
        var meta = metadataService.currentMetadata(for: entry.id) ?? BlockMetadata()
        meta.tagId = entry.tagId
        meta.dayId = entry.dayId
        meta.status = markdownConverter.status(in: entry.content)
        meta.type = markdownConverter.type(in: entry.content)
        meta.layer = BlockLayer(rawValue: entry.layer) ?? .default
        meta.frontmatter_version = markdownConverter.frontmatterVersion(in: entry.content)
        return meta
    }

    private func loadBlocks() async {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("BlocksStore", operation: "load")
        defer { PerformanceTracker.shared.endStoreOperation("BlocksStore", operation: "load", signpostID: spID, startTime: spStart) }
        let entries = await indexCoordinator.fetchAllBlocks()
        if !entries.isEmpty {
            let loaded = entries.map { blockFrom(entry: $0) }.sorted { $0.date > $1.date }
            await MainActor.run {
                self.blocks = loaded
            }
            return
        }
        loadBlocksFromFiles()
    }

    @discardableResult
    func mutateFrontmatter(blockID: String, merge: [String: AnyCodableValue]) async throws -> Int {
        return try await frontmatterMutatorActor.enqueue(blockID: blockID) { [weak self] in
            try await self?.performFrontmatterMutation(blockID: blockID, merge: merge) ?? 0
        }
    }

    private func performFrontmatterMutation(blockID: String, merge: [String: AnyCodableValue]) async throws -> Int {
        guard let current = self.block(withId: blockID) else {
            throw FrontmatterMutationError.blockNotFound(blockID)
        }
        let currentVersion = current.metadata.frontmatter_version
        let newVersion = currentVersion + 1
        var mergeWithVersion = merge
        mergeWithVersion["frontmatter_version"] = .int(newVersion)
        let newMarkdown = FrontmatterEditor.upsert(in: current.markdown, values: mergeWithVersion)

        try await fileService.writeMarkdownToDisk(newMarkdown, url: current.url)

        guard let idx = self.indexOfBlock(id: blockID) else { return newVersion }
        let live = self.blocks[idx]
        var meta = live.metadata
        meta.frontmatter_version = newVersion
        meta.status = self.markdownConverter.status(in: newMarkdown)
        meta.type = self.markdownConverter.type(in: newMarkdown)
        let updated = Block(
            id: live.id,
            title: live.title,
            date: live.date,
            lastEdited: Date(),
            markdown: newMarkdown,
            url: live.url,
            tagId: meta.tagId,
            metadata: meta
        )
        self.blocks[idx] = updated
        self.changeReconciler.recordWrite(for: blockID)
        Task { [indexCoordinator] in
            await indexCoordinator.index(block: updated)
        }

        return newVersion
    }

    private func loadBlocksFromFiles() {
        let metadata = metadataService.blocksMetadata
        let converter = self.markdownConverter
        let fs = self.fileService
        let coordinator = self.indexCoordinator

        Task.detached(priority: .userInitiated) { [weak self] in
            let sorted = await fs.loadBlocksFromFiles(metadata: metadata, converter: converter)

            await coordinator.rebuildIndex(blocks: sorted)

            await MainActor.run { [weak self] in
                self?.blocks = sorted
            }
        }
    }

}

enum FrontmatterMutationError: Error, Equatable {
    case blockNotFound(String)
}

actor FrontmatterMutatorActor {
    private var tails: [String: Task<Int, Error>] = [:]

    func enqueue(blockID: String, work: @escaping @Sendable () async throws -> Int) async throws -> Int {
        let prior = tails[blockID]
        let task = Task<Int, Error> {
            if let prior {
                _ = try? await prior.value
            }
            return try await work()
        }
        tails[blockID] = task
        defer {
            if tails[blockID] == task {
                tails[blockID] = nil
            }
        }
        return try await task.value
    }
}

enum FrontmatterEditor {
    static func upsert(in markdown: String, values: [String: AnyCodableValue]) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var leadingBlankCount = 0
        while leadingBlankCount < lines.count,
              lines[leadingBlankCount].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            leadingBlankCount += 1
        }
        let hasOpen = leadingBlankCount < lines.count
            && lines[leadingBlankCount].trimmingCharacters(in: .whitespacesAndNewlines) == "---"

        guard hasOpen else {
            return buildFresh(values: values) + (markdown.isEmpty ? "" : markdown)
        }

        var closeIndex: Int = -1
        var frontmatterLines: [String] = []
        var i = leadingBlankCount + 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" {
                closeIndex = i
                break
            }
            frontmatterLines.append(lines[i])
            i += 1
        }
        if closeIndex == -1 {
            return buildFresh(values: values) + markdown
        }

        var remaining = values
        var newFrontmatter: [String] = []
        for line in frontmatterLines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            if let newValue = remaining.removeValue(forKey: key) {
                newFrontmatter.append("\(key): \(serialize(newValue))")
            } else {
                newFrontmatter.append(line)
            }
        }
        for key in remaining.keys.sorted() {
            guard let value = remaining[key] else { continue }
            newFrontmatter.append("\(key): \(serialize(value))")
        }

        var rebuilt: [String] = []
        rebuilt.append(contentsOf: lines.prefix(leadingBlankCount))
        rebuilt.append("---")
        rebuilt.append(contentsOf: newFrontmatter)
        rebuilt.append("---")
        rebuilt.append(contentsOf: lines.dropFirst(closeIndex + 1))
        return rebuilt.joined(separator: "\n")
    }

    private static func buildFresh(values: [String: AnyCodableValue]) -> String {
        var block = "---\n"
        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            block += "\(key): \(serialize(value))\n"
        }
        block += "---\n"
        return block
    }

    static func serialize(_ value: AnyCodableValue) -> String {
        switch value {
        case .string(let s):
            return s
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return ""
        case .array(let arr):
            let items = arr.map { serialize($0) }
            return "[\(items.joined(separator: ", "))]"
        case .object:
            return ""
        }
    }
}

struct BlockCheckbox: Hashable, Sendable {
    let text: String
    let checked: Bool
    let lineNumber: Int
}

struct BlockCheckboxSnapshot: Hashable, Sendable {
    let text: String
    let wasChecked: Bool
}

enum BlockCheckboxError: Error, Equatable {
    case blockNotFound
    case lineNotFound
    case notACheckbox
    case persistenceFailed
}

private enum BlockCheckboxParsing {
    static let openPattern = #"^(\s*(?:[-*+]\s+|\d+\.\s+)\[)( )(\]\s+)(.*)$"#
    static let closedPattern = #"^(\s*(?:[-*+]\s+|\d+\.\s+)\[)([xX])(\]\s+)(.*)$"#
    static let fencePattern = #"^\s*```"#

    static let openRegex = try! NSRegularExpression(pattern: openPattern)
    static let closedRegex = try! NSRegularExpression(pattern: closedPattern)
    static let fenceRegex = try! NSRegularExpression(pattern: fencePattern)

    static func splitLines(_ markdown: String) -> [String] {
        markdown.components(separatedBy: "\n")
    }

    static func codeBlockMask(for lines: [String]) -> [Bool] {
        var mask = [Bool](repeating: false, count: lines.count)
        var inFence = false
        for (i, line) in lines.enumerated() {
            let nsLine = line as NSString
            let isFence = fenceRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) != nil
            if isFence {
                mask[i] = true
                inFence.toggle()
            } else {
                mask[i] = inFence
            }
        }
        return mask
    }

    enum CheckboxMatch {
        case open(text: String)
        case closed(text: String)
    }

    static func match(line: String) -> CheckboxMatch? {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        if let m = openRegex.firstMatch(in: line, range: range), m.numberOfRanges >= 5 {
            let textRange = m.range(at: 4)
            let text = nsLine.substring(with: textRange)
            return .open(text: text)
        }
        if let m = closedRegex.firstMatch(in: line, range: range), m.numberOfRanges >= 5 {
            let textRange = m.range(at: 4)
            let text = nsLine.substring(with: textRange)
            return .closed(text: text)
        }
        return nil
    }

    static func toggled(line: String) -> String? {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        if let m = openRegex.firstMatch(in: line, range: range), m.numberOfRanges >= 5 {
            let prefix = nsLine.substring(with: m.range(at: 1))
            let suffix = nsLine.substring(with: m.range(at: 3))
            let text = nsLine.substring(with: m.range(at: 4))
            return "\(prefix)x\(suffix)\(text)"
        }
        if let m = closedRegex.firstMatch(in: line, range: range), m.numberOfRanges >= 5 {
            let prefix = nsLine.substring(with: m.range(at: 1))
            let suffix = nsLine.substring(with: m.range(at: 3))
            let text = nsLine.substring(with: m.range(at: 4))
            return "\(prefix) \(suffix)\(text)"
        }
        return nil
    }

    static func uncheck(line: String) -> String? {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let m = closedRegex.firstMatch(in: line, range: range), m.numberOfRanges >= 5 else {
            return nil
        }
        let prefix = nsLine.substring(with: m.range(at: 1))
        let suffix = nsLine.substring(with: m.range(at: 3))
        let text = nsLine.substring(with: m.range(at: 4))
        return "\(prefix) \(suffix)\(text)"
    }
}

extension BlocksStore {

    func checkboxes(in blockId: String) -> [BlockCheckbox] {
        guard let block = block(withId: blockId) else { return [] }
        let lines = BlockCheckboxParsing.splitLines(block.markdown)
        let inCode = BlockCheckboxParsing.codeBlockMask(for: lines)
        var result: [BlockCheckbox] = []
        for (idx, line) in lines.enumerated() where !inCode[idx] {
            guard let match = BlockCheckboxParsing.match(line: line) else { continue }
            switch match {
            case .open(let text):
                result.append(BlockCheckbox(text: text, checked: false, lineNumber: idx + 1))
            case .closed(let text):
                result.append(BlockCheckbox(text: text, checked: true, lineNumber: idx + 1))
            }
        }
        return result
    }

    func toggleCheckbox(in blockId: String, lineNumber: Int) async throws {
        guard let block = block(withId: blockId) else {
            throw BlockCheckboxError.blockNotFound
        }
        var lines = BlockCheckboxParsing.splitLines(block.markdown)
        let inCode = BlockCheckboxParsing.codeBlockMask(for: lines)
        let index = lineNumber - 1
        guard index >= 0, index < lines.count else {
            throw BlockCheckboxError.lineNotFound
        }
        guard !inCode[index] else {
            throw BlockCheckboxError.notACheckbox
        }
        guard let toggled = BlockCheckboxParsing.toggled(line: lines[index]) else {
            throw BlockCheckboxError.notACheckbox
        }
        lines[index] = toggled
        let newMarkdown = lines.joined(separator: "\n")
        let success = await updateBlock(block, newMarkdown: newMarkdown)
        if !success {
            throw BlockCheckboxError.persistenceFailed
        }
    }

    @discardableResult
    func resetCheckedCheckboxes(in blockId: String) async throws -> [BlockCheckboxSnapshot] {
        guard let block = block(withId: blockId) else {
            throw BlockCheckboxError.blockNotFound
        }
        var lines = BlockCheckboxParsing.splitLines(block.markdown)
        let inCode = BlockCheckboxParsing.codeBlockMask(for: lines)
        var snapshots: [BlockCheckboxSnapshot] = []
        var didMutate = false
        for (idx, line) in lines.enumerated() where !inCode[idx] {
            guard let match = BlockCheckboxParsing.match(line: line) else { continue }
            switch match {
            case .open(let text):
                snapshots.append(BlockCheckboxSnapshot(text: text, wasChecked: false))
            case .closed(let text):
                snapshots.append(BlockCheckboxSnapshot(text: text, wasChecked: true))
                if let unchecked = BlockCheckboxParsing.uncheck(line: line) {
                    lines[idx] = unchecked
                    didMutate = true
                }
            }
        }
        if didMutate {
            let newMarkdown = lines.joined(separator: "\n")
            let success = await updateBlock(block, newMarkdown: newMarkdown)
            if !success {
                throw BlockCheckboxError.persistenceFailed
            }
        }
        return snapshots
    }
}
