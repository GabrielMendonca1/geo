import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "BlockChangeReconciler")

extension Notification.Name {
    static let blocksExternallyChanged = Notification.Name("ai.geo.blocksExternallyChanged")
}

enum BlockExternalChangeKey {
    static let changedIds = "changedIds"
    static let removedIds = "removedIds"
}

@MainActor
final class BlockChangeReconciler {
    private let fileManager = FileManager.default
    private let timestampLock = NSLock()
    private var recentWriteTimestamps: [String: Date] = [:]
    private let externalWriteGracePeriod: TimeInterval = 1.0
    private let fileService: BlockFileService
    private let metadataService: BlockMetadataService
    private let indexCoordinator: IndexCoordinator
    private var fileWatcher: FileWatcherService?

    var onBlocksChanged: (([BlocksStore.Block]) -> Void)?
    var currentBlocksProvider: (() -> [BlocksStore.Block])?

    init(
        fileService: BlockFileService,
        metadataService: BlockMetadataService,
        indexCoordinator: IndexCoordinator
    ) {
        self.fileService = fileService
        self.metadataService = metadataService
        self.indexCoordinator = indexCoordinator
    }

    func startWatching() {
        let watcher = FileWatcherService(url: fileService.blocksDirectory)
        watcher.onChange = { [weak self] (urls: [URL]) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleExternalChanges(urls, currentBlocks: self.currentBlocksProvider?() ?? [])
            }
        }
        watcher.start()
        fileWatcher = watcher
    }

    func recordWrite(for blockId: String) {
        timestampLock.lock()
        recentWriteTimestamps[blockId] = Date()
        timestampLock.unlock()
    }

    func handleExternalChanges(_ urls: [URL], currentBlocks: [BlocksStore.Block]? = nil) {
        pruneWriteTimestamps()
        let now = Date()
        let blocks = currentBlocks ?? []

        let metadataChanged = urls.contains { $0.lastPathComponent == ".blocks-metadata.json" }
        if metadataChanged && now.timeIntervalSince(metadataService.currentLastWriteTime()) >= externalWriteGracePeriod {
            metadataService.loadMetadata()
            var updatedBlocks = blocks
            var metadataChangedIds: [String] = []
            for i in updatedBlocks.indices {
                let block = updatedBlocks[i]
                let meta = metadataService.metadata(for: block.id)
                if block.metadata != meta {
                    updatedBlocks[i] = BlocksStore.Block(
                        id: block.id,
                        title: block.title,
                        date: block.date,
                        lastEdited: block.lastEdited,
                        markdown: block.markdown,
                        url: block.url,
                        tagId: meta.tagId,
                        metadata: meta
                    )
                    metadataChangedIds.append(block.id)
                }
            }
            if !metadataChangedIds.isEmpty {
                onBlocksChanged?(updatedBlocks)
                NotificationCenter.default.post(
                    name: .blocksExternallyChanged,
                    object: nil,
                    userInfo: [
                        BlockExternalChangeKey.changedIds: metadataChangedIds,
                        BlockExternalChangeKey.removedIds: [String]()
                    ]
                )
            }
        }

        let relevant = urls.filter { $0.pathExtension.lowercased() == "md" }
        guard !relevant.isEmpty else { return }
        let resourceKeys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let latestBlocks: [BlocksStore.Block]
        if metadataChanged {
            latestBlocks = blocks
        } else {
            latestBlocks = blocks
        }
        var updatedBlocks = latestBlocks
        var blocksToIndex: [BlocksStore.Block] = []
        var removedIds: [String] = []
        var externallyChangedIds: [String] = []
        var metadataDirty = false

        for url in relevant {
            let blockId = url.lastPathComponent
            if shouldIgnoreExternalChange(for: blockId, at: now) {
                continue
            }
            if fileManager.fileExists(atPath: url.path) {
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                var blockMetadata = metadataService.metadata(for: blockId)
                blockMetadata.status = MarkdownConverter.shared.status(in: content)
                blockMetadata.type = MarkdownConverter.shared.type(in: content)
                let diskFrontmatterVersion = MarkdownConverter.shared.frontmatterVersion(in: content)
                let memBlock = blocks.first(where: { $0.id == blockId })
                if memBlock?.markdown == content {
                    continue
                }
                blockMetadata.frontmatter_version = max(diskFrontmatterVersion, memBlock?.metadata.frontmatter_version ?? 0)
                let title = fileService.titleFromMarkdown(content, fallback: "", allowTodoTitle: false)
                let resourceValues = try? url.resourceValues(forKeys: resourceKeys)
                let date = resourceValues?.creationDate ?? Date()
                let lastEdited = resourceValues?.contentModificationDate ?? date
                let block = BlocksStore.Block(
                    id: blockId,
                    title: title,
                    date: date,
                    lastEdited: lastEdited,
                    markdown: content,
                    url: url,
                    tagId: blockMetadata.tagId,
                    metadata: blockMetadata
                )
                if let index = updatedBlocks.firstIndex(where: { $0.id == blockId }) {
                    let existing = updatedBlocks[index]
                    if existing.markdown != content || existing.tagId != blockMetadata.tagId {
                        updatedBlocks[index] = block
                        externallyChangedIds.append(blockId)
                    }
                } else {
                    updatedBlocks.append(block)
                    externallyChangedIds.append(blockId)
                }
                blocksToIndex.append(block)
            } else {
                if let index = updatedBlocks.firstIndex(where: { $0.id == blockId }) {
                    updatedBlocks.remove(at: index)
                }
                metadataService.removeMetadata(for: blockId)
                metadataDirty = true
                removedIds.append(blockId)
            }
        }

        if updatedBlocks != latestBlocks {
            updatedBlocks.sort { $0.date > $1.date }
            onBlocksChanged?(updatedBlocks)
        }
        if metadataDirty {
            metadataService.saveMetadata()
        }
        for block in blocksToIndex {
            Task {
                await indexCoordinator.index(block: block)
            }
        }
        for id in removedIds {
            Task {
                await indexCoordinator.remove(blockId: id)
            }
        }
        if !externallyChangedIds.isEmpty || !removedIds.isEmpty {
            NotificationCenter.default.post(
                name: .blocksExternallyChanged,
                object: nil,
                userInfo: [
                    BlockExternalChangeKey.changedIds: externallyChangedIds,
                    BlockExternalChangeKey.removedIds: removedIds
                ]
            )
        }
    }

    private func pruneWriteTimestamps() {
        timestampLock.lock()
        let cutoff = Date().addingTimeInterval(-externalWriteGracePeriod * 2)
        recentWriteTimestamps = recentWriteTimestamps.filter { $0.value > cutoff }
        timestampLock.unlock()
    }

    private func shouldIgnoreExternalChange(for blockId: String, at date: Date) -> Bool {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        guard let lastWrite = recentWriteTimestamps[blockId] else { return false }
        return abs(date.timeIntervalSince(lastWrite)) < externalWriteGracePeriod
    }
}
