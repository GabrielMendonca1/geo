import Combine
import Foundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "BlocksViewModel")

enum GroupingMode: String, CaseIterable, Identifiable {
    case none
    case folder
    case date
    case tag

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:
            return "No Grouping"
        case .folder:
            return "Folder"
        case .date:
            return "Date"
        case .tag:
            return "Tag"
        }
    }
}

enum BlockSortField: String, CaseIterable, Identifiable {
    case lastEdited
    case created

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastEdited:
            return "Last Edited"
        case .created:
            return "Created"
        }
    }
}

enum BlockSortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest:
            return "Newest First"
        case .oldest:
            return "Oldest First"
        }
    }

    var systemImageName: String {
        switch self {
        case .newest:
            return "arrow.down"
        case .oldest:
            return "arrow.up"
        }
    }

    mutating func toggle() {
        self = self == .newest ? .oldest : .newest
    }
}

enum DateGroup: Int, CaseIterable {
    case today
    case yesterday
    case lastWeek
    case earlier

    var id: String {
        switch self {
        case .today:
            return "today"
        case .yesterday:
            return "yesterday"
        case .lastWeek:
            return "last-week"
        case .earlier:
            return "earlier"
        }
    }

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .yesterday:
            return "Yesterday"
        case .lastWeek:
            return "Last Week"
        case .earlier:
            return "Earlier"
        }
    }
}

struct BlockGroup: Identifiable {
    let id: String
    let title: String
    let color: Color?
    let blocks: [BlockEntity]
}

final class FolderNode: Identifiable {
    let id: String
    let name: String
    let subfolders: [FolderNode]
    let blocks: [BlockEntity]

    var path: String { id }
    var isEmpty: Bool { subfolders.isEmpty && blocks.isEmpty }
    var totalBlockCount: Int {
        blocks.count + subfolders.reduce(0) { $0 + $1.totalBlockCount }
    }

    init(id: String, name: String, subfolders: [FolderNode], blocks: [BlockEntity]) {
        self.id = id
        self.name = name
        self.subfolders = subfolders
        self.blocks = blocks
    }

    final class Builder {
        let name: String
        private var children: [String: Builder] = [:]
        var blocks: [BlockEntity] = []

        init(name: String) { self.name = name }

        func folder(at components: [String]) -> Builder {
            var node = self
            for component in components {
                if let existing = node.children[component] {
                    node = existing
                } else {
                    let child = Builder(name: component)
                    node.children[component] = child
                    node = child
                }
            }
            return node
        }

        func build(path: String) -> FolderNode {
            let subfolders = children.values
                .map { child -> FolderNode in
                    let childPath = path.isEmpty ? child.name : path + "/" + child.name
                    return child.build(path: childPath)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return FolderNode(id: path, name: name, subfolders: subfolders, blocks: blocks)
        }
    }
}

@MainActor
final class BlocksViewModel: ObservableObject {
    @Published private(set) var blocks: [BlockEntity] = []
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var hasLoadedInitialSnapshot = false

    private var tagIndex: [String: Tag] = [:]
    private var observeBlocksTask: Task<Void, Never>?
    private var observeTagsTask: Task<Void, Never>?
    private var repository: (any BlocksRepository)?
    private var tagsRepository: (any TagsRepository)?
    private var blocksStore: BlocksStore?
    private var isBound = false

    deinit {
        observeBlocksTask?.cancel()
        observeTagsTask?.cancel()
    }

    func bindIfNeeded(
        blocksRepository: any BlocksRepository,
        tagsRepository: any TagsRepository,
        blocksStore: BlocksStore? = nil
    ) {
        guard !isBound else { return }
        bind(blocksRepository: blocksRepository, tagsRepository: tagsRepository, blocksStore: blocksStore)
    }

    func bind(
        blocksRepository: any BlocksRepository,
        tagsRepository: any TagsRepository,
        blocksStore: BlocksStore? = nil
    ) {
        repository = blocksRepository
        self.tagsRepository = tagsRepository
        self.blocksStore = blocksStore
        isBound = true
        hasLoadedInitialSnapshot = false
        observeBlocksTask?.cancel()
        observeTagsTask?.cancel()

        observeBlocksTask = Task { [weak self] in
            var didReceiveInitialSnapshot = false
            for await observedBlocks in blocksRepository.observe() {
                guard !Task.isCancelled, let self else { break }
                self.blocks = observedBlocks
                if !self.statusCache.isEmpty {
                    let liveIds = Set(observedBlocks.map(\.id))
                    self.statusCache = self.statusCache.filter { liveIds.contains($0.key) }
                }
                if !didReceiveInitialSnapshot {
                    self.hasLoadedInitialSnapshot = true
                    didReceiveInitialSnapshot = true
                }
            }
        }

        observeTagsTask = Task { [weak self] in
            for await observedTags in tagsRepository.observe() {
                guard !Task.isCancelled, let self else { break }
                self.tags = observedTags
                var index: [String: Tag] = [:]
                for tag in observedTags {
                    let key = TagStore.canonicalName(tag.name)
                    if index[key] == nil { index[key] = tag }
                }
                self.tagIndex = index
            }
        }
    }

    func block(withID id: String) -> BlockEntity? {
        blocks.first(where: { $0.id == id })
    }

    func tag(for id: String?) -> Tag? {
        guard let id else { return nil }
        return tags.first(where: { $0.id == id })
    }

    func tag(forName name: String?) -> Tag? {
        guard let name else { return nil }
        let canonical = TagStore.canonicalName(name)
        if let existing = tagIndex[canonical] {
            return existing
        }
        return Tag(id: canonical, name: name, color: TagStore.defaultColor(forName: canonical))
    }

    func resolvedTag(for block: BlockEntity) -> Tag? {
        tag(forName: block.metadata.tagName)
    }

    func resolvedTagKey(for block: BlockEntity) -> String? {
        guard let name = block.metadata.tagName else { return nil }
        return TagStore.canonicalName(name)
    }

    func createBlock(title: String, markdown: String) async -> BlockEntity? {
        guard let repository else { return nil }

        do {
            return try await repository.create(title: title, markdown: markdown)
        } catch {
            logger.error("Failed to create block: \(error.localizedDescription)")
            return nil
        }
    }

    func createBlock(title: String, markdown: String, folder: String?) async -> BlockEntity? {
        guard let repository else { return nil }

        do {
            return try await repository.create(title: title, markdown: markdown, folder: folder)
        } catch {
            logger.error("Failed to create block in \(folder ?? "root"): \(error.localizedDescription)")
            return nil
        }
    }

    func moveBlock(id: String, toFolder folder: String?) async -> Bool {
        guard let repository else { return false }

        do {
            _ = try await repository.move(id: id, toFolder: folder)
            return true
        } catch {
            logger.error("Failed to move block \(id) to \(folder ?? "root"): \(error.localizedDescription)")
            return false
        }
    }

    func createFolder(_ folder: String) async -> Bool {
        guard let repository else { return false }

        do {
            try await repository.createFolder(folder)
            return true
        } catch {
            logger.error("Failed to create folder \(folder): \(error.localizedDescription)")
            return false
        }
    }

    func listFolders() async -> [String] {
        guard let repository else { return [] }
        return await repository.listFolders()
    }

    func updateBlock(id: String, markdown: String) async -> Bool {
        guard let repository else { return false }

        do {
            try await repository.update(id: id, markdown: markdown)
            return true
        } catch {
            logger.error("Failed to update block \(id): \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    func saveBlockSync(id: String, markdown: String) {
        if let repository {
            _ = repository.saveSync(id: id, markdown: markdown)
        } else {
            Task {
                _ = await updateBlock(id: id, markdown: markdown)
            }
        }
    }

    @MainActor
    func setFocusedBlock(_ id: String?) {
        blocksStore?.setFocusedBlock(id)
    }

    @MainActor
    func clearFocusedBlock(ifMatching id: String) {
        guard let blocksStore else { return }
        if blocksStore.focusedBlockId == id {
            blocksStore.setFocusedBlock(nil)
        }
    }

    func deleteBlock(id: String) async -> Bool {
        guard let repository else { return false }

        do {
            try await repository.delete(id: id)
            return true
        } catch {
            logger.error("Failed to delete block \(id): \(error.localizedDescription)")
            return false
        }
    }

    func setTag(_ tagId: String?, for blockId: String) async -> Bool {
        guard let repository else { return false }

        do {
            try await repository.setTag(blockId: blockId, tagId: tagId)
            return true
        } catch {
            logger.error("Failed to set tag on block \(blockId): \(error.localizedDescription)")
            return false
        }
    }

    func setFullWidth(_ isFullWidth: Bool, for blockId: String) async -> Bool {
        guard let repository else { return false }

        do {
            try await repository.setFullWidth(blockId: blockId, isFullWidth: isFullWidth)
            return true
        } catch {
            logger.error("Failed to set full width on block \(blockId): \(error.localizedDescription)")
            return false
        }
    }

    func setLayer(_ layer: BlockLayer, for blockId: String) async -> Bool {
        guard let repository else { return false }

        do {
            try await repository.setLayer(blockId: blockId, layer: layer)
            return true
        } catch {
            logger.error("Failed to set layer on block \(blockId): \(error.localizedDescription)")
            return false
        }
    }

    func setType(_ type: BlockType, for blockId: String) async -> Bool {
        guard let repository else { return false }

        do {
            try await repository.setType(blockId: blockId, type: type)
            return true
        } catch {
            logger.error("Failed to set type on block \(blockId): \(error.localizedDescription)")
            return false
        }
    }

    func setStatus(_ status: String?, for blockId: String) async -> Bool {
        guard let repository else { return false }

        do {
            try await repository.setStatus(blockId: blockId, status: status)
            return true
        } catch {
            logger.error("Failed to set status on block \(blockId): \(error.localizedDescription)")
            return false
        }
    }

    func clearTagAssignments(for tagId: String) async {
        let tagKey = tag(for: tagId).map { TagStore.canonicalName($0.name) }
        let targetIds = blocks
            .filter { block in
                if let key = resolvedTagKey(for: block) {
                    return key == tagId || (tagKey != nil && key == tagKey)
                }
                return false
            }
            .map(\.id)

        guard !targetIds.isEmpty else { return }

        for blockId in targetIds {
            _ = await setTag(nil, for: blockId)
        }
    }

    func createTag(name: String, color: TagColor) async -> Result<Tag, Error> {
        guard let tagsRepository else {
            return .failure(RepositoryError.invalidInput)
        }

        do {
            let tag = try await tagsRepository.create(name: name, color: color)
            return .success(tag)
        } catch {
            return .failure(error)
        }
    }

    func updateTag(id: String, name: String, color: TagColor) async -> Result<Tag, Error> {
        guard let tagsRepository else {
            return .failure(RepositoryError.invalidInput)
        }

        guard var tag = tags.first(where: { $0.id == id }) else {
            return .failure(RepositoryError.notFound)
        }

        tag.name = name
        tag.color = color

        do {
            let updatedTag = try await tagsRepository.update(tag)
            return .success(updatedTag)
        } catch {
            return .failure(error)
        }
    }

    func deleteTag(id: String) async -> Bool {
        guard let tagsRepository else { return false }

        do {
            try await tagsRepository.delete(id: id)
            return true
        } catch {
            return false
        }
    }

    func searchBlocks(matching query: String) async -> [BlockEntity] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        guard let repository else {
            return []
        }

        do {
            return try await repository.search(matching: trimmedQuery)
        } catch {
            return []
        }
    }

    func filteredBlocks(
        debouncedSearchText: String,
        searchResults: [BlockEntity],
        selectedTagFilter: String?,
        taskFilter: Set<String>?,
        statusFilter: BlockStatusFilter,
        sortField: BlockSortField,
        sortOrder: BlockSortOrder
    ) -> [BlockEntity] {
        let matches = debouncedSearchText.isEmpty ? blocks : searchResults

        let tagFiltered: [BlockEntity]
        if let tagFilter = selectedTagFilter {
            if tagFilter == "untagged" {
                tagFiltered = matches.filter { resolvedTagKey(for: $0) == nil }
            } else {
                let filterKey = TagStore.canonicalName(tagFilter)
                tagFiltered = matches.filter { block in
                    guard let key = resolvedTagKey(for: block) else { return false }
                    return key == filterKey || key == tagFilter
                }
            }
        } else {
            tagFiltered = matches
        }

        let taskFiltered: [BlockEntity]
        if let taskFilter {
            taskFiltered = tagFiltered.filter { taskFilter.contains($0.id) }
        } else {
            taskFiltered = tagFiltered
        }

        let statusFiltered = taskFiltered.filter { block in
            statusFilter.includes(status: resolvedStatus(for: block))
        }

        return statusFiltered.sorted { lhs, rhs in
            blockSortOrder(lhs, rhs, sortField: sortField, sortOrder: sortOrder)
        }
    }

    private var statusCache: [String: (lastEdited: Date, status: String?)] = [:]

    private func resolvedStatus(for block: BlockEntity) -> String? {
        if let metaStatus = block.metadata.status, !metaStatus.isEmpty {
            return metaStatus
        }
        if let cached = statusCache[block.id], cached.lastEdited == block.lastEdited {
            return cached.status
        }
        let status = MarkdownConverter.shared.status(in: block.markdown)
        statusCache[block.id] = (block.lastEdited, status)
        return status
    }

    func blockGroups(
        for blocks: [BlockEntity],
        groupingMode: GroupingMode,
        sortField: BlockSortField,
        sortOrder: BlockSortOrder
    ) -> [BlockGroup] {
        switch groupingMode {
        case .none, .folder:
            return []
        case .date:
            return groupBlocksByDate(blocks, sortField: sortField, sortOrder: sortOrder)
        case .tag:
            return groupBlocksByTag(blocks, tags: tags)
        }
    }

    func folderTree(for blocks: [BlockEntity], extraFolders: [String] = []) -> FolderNode {
        let root = FolderNode.Builder(name: "")
        for folder in extraFolders {
            _ = root.folder(at: Self.folderComponents(folder))
        }
        for block in blocks {
            let components = block.id.split(separator: "/").map(String.init)
            let folderComponents = Array(components.dropLast())
            root.folder(at: folderComponents).blocks.append(block)
        }
        return root.build(path: "")
    }

    private static func folderComponents(_ folder: String) -> [String] {
        folder.split(separator: "/").map(String.init)
    }

    private func sortDate(for block: BlockEntity, sortField: BlockSortField) -> Date {
        switch sortField {
        case .lastEdited:
            return block.lastEdited
        case .created:
            return block.date
        }
    }

    private func blockSortOrder(
        _ lhs: BlockEntity,
        _ rhs: BlockEntity,
        sortField: BlockSortField,
        sortOrder: BlockSortOrder
    ) -> Bool {
        let lhsDate = sortDate(for: lhs, sortField: sortField)
        let rhsDate = sortDate(for: rhs, sortField: sortField)
        if lhsDate == rhsDate {
            return sortOrder == .newest ? lhs.id > rhs.id : lhs.id < rhs.id
        }
        return sortOrder == .newest ? lhsDate > rhsDate : lhsDate < rhsDate
    }

    private func groupBlocksByDate(
        _ blocks: [BlockEntity],
        sortField: BlockSortField,
        sortOrder: BlockSortOrder
    ) -> [BlockGroup] {
        var grouped: [DateGroup: [BlockEntity]] = [:]
        for block in blocks {
            let key = dateGroup(for: sortDate(for: block, sortField: sortField))
            grouped[key, default: []].append(block)
        }

        let orderedKeys = sortOrder == .newest ? DateGroup.allCases : Array(DateGroup.allCases.reversed())
        return orderedKeys.compactMap { key in
            guard let items = grouped[key], !items.isEmpty else { return nil }
            return BlockGroup(id: key.id, title: key.title, color: nil, blocks: items)
        }
    }

    private func groupBlocksByTag(_ blocks: [BlockEntity], tags: [Tag]) -> [BlockGroup] {
        var grouped: [String: [BlockEntity]] = [:]
        var resolvedTagByKey: [String: Tag] = [:]
        var keyOrder: [String] = []
        var untagged: [BlockEntity] = []

        for block in blocks {
            guard let key = resolvedTagKey(for: block) else {
                untagged.append(block)
                continue
            }
            if grouped[key] == nil { keyOrder.append(key) }
            grouped[key, default: []].append(block)
            if resolvedTagByKey[key] == nil { resolvedTagByKey[key] = resolvedTag(for: block) }
        }

        var results: [BlockGroup] = []
        for key in keyOrder {
            guard let items = grouped[key], !items.isEmpty else { continue }
            let tag = resolvedTagByKey[key]
            results.append(
                BlockGroup(
                    id: key,
                    title: tag?.name ?? key,
                    color: tag?.color.swiftUIColor,
                    blocks: items
                )
            )
        }

        if !untagged.isEmpty {
            results.append(BlockGroup(id: "untagged", title: "Untagged", color: nil, blocks: untagged))
        }

        return results
    }

    private func dateGroup(for date: Date) -> DateGroup {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return .today
        }
        if calendar.isDateInYesterday(date) {
            return .yesterday
        }
        if let lastWeek = calendar.date(byAdding: .day, value: -7, to: Date()), date >= lastWeek {
            return .lastWeek
        }
        return .earlier
    }
}

extension BlocksViewModel {
    func setStatus(_ status: BlockStatus, for blockId: String) async -> Bool {
        await setStatus(status.rawValue, for: blockId)
    }
}

extension BlocksViewModel {
    func focusedBlockPublisher(id: String) -> AnyPublisher<BlockEntity?, Never> {
        $blocks
            .map { $0.first(where: { $0.id == id }) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var blocksCountPublisher: AnyPublisher<Int, Never> {
        $blocks
            .map { $0.count }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
