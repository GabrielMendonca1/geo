import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "BlocksStore")

@MainActor
class BlocksStore: ObservableObject {

    @Published private(set) var blocks: [Block] = []
    @Published private(set) var focusedBlockId: String?

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

        init(
            dayId: String? = nil,
            tagId: String? = nil,
            isFullWidth: Bool = false,
            status: String? = nil,
            type: BlockType = .fleeting,
            layer: BlockLayer = .default
        ) {
            self.dayId = dayId
            self.tagId = tagId
            self.isFullWidth = isFullWidth
            self.status = status
            self.type = type
            self.layer = layer
        }

        enum CodingKeys: String, CodingKey {
            case dayId, tagId, isFullWidth, status, type, layer
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            dayId = try container.decodeIfPresent(String.self, forKey: .dayId)
            tagId = try container.decodeIfPresent(String.self, forKey: .tagId)
            isFullWidth = try container.decodeIfPresent(Bool.self, forKey: .isFullWidth) ?? false
            status = try container.decodeIfPresent(String.self, forKey: .status)
            type = try container.decodeIfPresent(BlockType.self, forKey: .type) ?? .fleeting
            layer = try container.decodeIfPresent(BlockLayer.self, forKey: .layer) ?? .default
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
        }

        var isPersisted: Bool {
            dayId != nil || tagId != nil || isFullWidth || status != nil || layer != .default
        }
    }

    let fileService: BlockFileService
    let metadataService: BlockMetadataService
    let changeReconciler: BlockChangeReconciler
    private let indexCoordinator: IndexCoordinator
    private let dayManager: DayManager
    private let markdownConverter: MarkdownConverter
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

        Task { [weak metadataService, indexCoordinator] in
            let snapshot = await indexCoordinator.fetchAllMetadata()
            await MainActor.run {
                metadataService?.hydrateFromIndex(snapshot)
            }
        }

        reconciler.onBlocksChanged = { [weak self] updatedBlocks in
            self?.blocks = updatedBlocks
        }
        reconciler.currentBlocksProvider = { [weak self] in
            self?.blocks ?? []
        }

        if enableWatcher {
            reconciler.startWatching()
        }

        if loadAsync {
            Task.detached(priority: .userInitiated) {
                await self.loadBlocks()
            }
        } else {
            Task {
                await loadBlocks()
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
    func createBlock(title: String, markdown: String) async -> Block? {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("BlocksStore", operation: "create")
        defer { PerformanceTracker.shared.endStoreOperation("BlocksStore", operation: "create", signpostID: spID, startTime: spStart) }
        let sanitized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = sanitized.isEmpty ? "Block" : sanitized

        let uniqueName = fileService.uniqueFilename(for: filename)
        let url = fileService.blocksDirectory.appendingPathComponent(uniqueName).appendingPathExtension("md")

        let body = markdown.isEmpty ? (sanitized.isEmpty ? "" : "# \(sanitized)\n") : markdown

        let now = Date()
        let metadata = BlockMetadata()
        let newBlock = Block(
            id: url.lastPathComponent,
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
        guard let index = self.blocks.firstIndex(where: { $0.id == block.id }) else {
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
        if let liveIndex = self.blocks.firstIndex(where: { $0.id == currentBlock.id }) {
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

            await indexCoordinator.index(block: snapshotForIndex, document: document)

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let liveIndex = self.blocks.firstIndex(where: { $0.id == blockId }),
                      self.blocks[liveIndex].markdown == newMarkdown else { return }
                let live = self.blocks[liveIndex]
                var meta = self.metadataService.currentMetadata(for: blockId) ?? live.metadata
                meta.status = status
                meta.type = type
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
        guard let index = self.blocks.firstIndex(where: { $0.id == id }) else {
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

        if let index = self.blocks.firstIndex(where: { $0.id == block.id }) {
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

        if let index = blocks.firstIndex(where: { $0.id == blockId }) {
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
        guard let block = blocks.first(where: { $0.id == blockId }) else { return false }
        let newMarkdown = Self.applyFrontmatter(to: block.markdown, key: "type", value: type.rawValue)
        updateBlockMetadata(for: blockId) { metadata in
            metadata.type = type
        }
        return await updateBlock(block, newMarkdown: newMarkdown)
    }

    @MainActor
    @discardableResult
    func setStatus(_ status: String?, for blockId: String) async -> Bool {
        guard let block = blocks.first(where: { $0.id == blockId }) else { return false }
        let newMarkdown = Self.applyFrontmatter(to: block.markdown, key: "status", value: status)
        updateBlockMetadata(for: blockId) { metadata in
            metadata.status = status
        }
        return await updateBlock(block, newMarkdown: newMarkdown)
    }

    static func applyFrontmatter(to markdown: String, key: String, value: String?) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var leadingBlankCount = 0
        while leadingBlankCount < lines.count,
              lines[leadingBlankCount].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            leadingBlankCount += 1
        }

        let hasFrontmatter = leadingBlankCount < lines.count
            && lines[leadingBlankCount].trimmingCharacters(in: .whitespacesAndNewlines) == "---"

        var openIndex: Int = leadingBlankCount
        var closeIndex: Int = -1
        var frontmatterLines: [String] = []

        if hasFrontmatter {
            var i = openIndex + 1
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
                return Self.insertFreshFrontmatter(into: markdown, key: key, value: value)
            }
        } else {
            return Self.insertFreshFrontmatter(into: markdown, key: key, value: value)
        }

        var foundKey = false
        var newFrontmatter: [String] = []
        for line in frontmatterLines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let lineKey = parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            if lineKey == key {
                foundKey = true
                if let value, !value.isEmpty {
                    newFrontmatter.append("\(key): \(value)")
                }
            } else {
                newFrontmatter.append(line)
            }
        }

        if !foundKey, let value, !value.isEmpty {
            newFrontmatter.append("\(key): \(value)")
        }

        var rebuilt: [String] = []
        rebuilt.append(contentsOf: lines.prefix(openIndex))
        if newFrontmatter.isEmpty {
            rebuilt.append(contentsOf: lines.dropFirst(closeIndex + 1))
        } else {
            rebuilt.append("---")
            rebuilt.append(contentsOf: newFrontmatter)
            rebuilt.append("---")
            rebuilt.append(contentsOf: lines.dropFirst(closeIndex + 1))
        }
        return rebuilt.joined(separator: "\n")
    }

    private static func insertFreshFrontmatter(into markdown: String, key: String, value: String?) -> String {
        guard let value, !value.isEmpty else { return markdown }
        let block = "---\n\(key): \(value)\n---\n"
        if markdown.isEmpty {
            return block
        }
        return block + markdown
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
        guard let block = blocks.first(where: { $0.id == blockId }) else { return [] }
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
        guard let block = blocks.first(where: { $0.id == blockId }) else {
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
        guard let block = blocks.first(where: { $0.id == blockId }) else {
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
