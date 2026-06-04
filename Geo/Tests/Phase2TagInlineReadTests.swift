import XCTest
@testable import Geo

@MainActor
final class Phase2TagInlineReadTests: XCTestCase {

    private func entity(id: String, tagName: String?) -> BlockEntity {
        BlockEntity(
            id: id,
            title: id,
            date: Date(),
            lastEdited: Date(),
            markdown: "# \(id)\n",
            url: URL(fileURLWithPath: "/tmp/\(id).md"),
            metadata: BlockEntity.Metadata(tagName: tagName)
        )
    }

    private func boundViewModel(blocks: [BlockEntity], tags: [Tag]) async -> BlocksViewModel {
        let vm = BlocksViewModel()
        vm.bind(
            blocksRepository: StubBlocksRepo(snapshot: blocks),
            tagsRepository: StubTagsRepo(snapshot: tags)
        )
        for _ in 0..<50 {
            if vm.blocks.count == blocks.count && vm.tags.count == tags.count { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return vm
    }

    private func arcTag(id: String = UUID().uuidString) -> Tag {
        Tag(id: id, name: "ARC", color: TagColor(red: 0.2, green: 0.4, blue: 0.8))
    }

    func testFrontmatterNameWinsWhenPresent() async {
        let tag = arcTag()
        let block = entity(id: "A", tagId: "stale-uuid", tagName: "arc")
        let vm = await boundViewModel(blocks: [block], tags: [tag])

        let resolved = vm.resolvedTag(for: block)
        XCTAssertEqual(resolved?.name, "ARC", "frontmatter-derived name resolves to central tag")
        XCTAssertEqual(vm.resolvedTagKey(for: block), "arc")
    }

    func testFallsBackToTagIdWhenFrontmatterNameAbsent() async {
        let tag = arcTag()
        let block = entity(id: "B", tagId: tag.id, tagName: nil)
        let vm = await boundViewModel(blocks: [block], tags: [tag])

        let resolved = vm.resolvedTag(for: block)
        XCTAssertEqual(resolved?.id, tag.id, "no frontmatter tag → UUID fallback keeps the tag (never dropped)")
        XCTAssertEqual(vm.resolvedTagKey(for: block), tag.id)
    }

    func testTagNeverDroppedForUntouchedBlock() async {
        let tag = arcTag()
        let block = entity(id: "C", tagId: tag.id, tagName: nil)
        let vm = await boundViewModel(blocks: [block], tags: [tag])
        XCTAssertNotNil(vm.resolvedTag(for: block))
    }

    func testGroupingCollapsesNameAndUUIDVariantsIntoOneGroupPerCanonicalName() async {
        let tag = arcTag()
        // one block via frontmatter name, one via #arc-body-derived name
        let viaName = entity(id: "name", tagId: nil, tagName: "arc")
        let viaBody = entity(id: "body", tagId: nil, tagName: "arc")
        let vm = await boundViewModel(blocks: [viaName, viaBody], tags: [tag])

        let groups = vm.blockGroups(for: vm.blocks, groupingMode: .tag, sortField: .created, sortOrder: .newest)
        let arcGroups = groups.filter { $0.title == "ARC" || $0.id == "arc" }
        XCTAssertEqual(arcGroups.count, 1, "single-group-per-canonical-name preserved")
        XCTAssertEqual(arcGroups.first?.blocks.count, 2)
    }

    func testGroupingUntaggedPreserved() async {
        let untagged = entity(id: "u", tagId: nil, tagName: nil)
        let vm = await boundViewModel(blocks: [untagged], tags: [])
        let groups = vm.blockGroups(for: vm.blocks, groupingMode: .tag, sortField: .created, sortOrder: .newest)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, "untagged")
    }

    func testFilterByNameMatchesFrontmatterDerivedBlocks() async {
        let tag = arcTag()
        let viaName = entity(id: "name", tagId: nil, tagName: "arc")
        let other = entity(id: "other", tagId: nil, tagName: "work")
        let vm = await boundViewModel(blocks: [viaName, other], tags: [tag])

        let filtered = vm.filteredBlocks(
            debouncedSearchText: "",
            searchResults: [],
            selectedTagFilter: "arc",
            hasTasksOnly: false,
            statusFilter: .all,
            sortField: .created,
            sortOrder: .newest,
            linkedPendingBlockIds: []
        )
        XCTAssertEqual(filtered.map(\.id), ["name"])
    }

    func testFilterUntaggedUsesDerivedKey() async {
        let withTag = entity(id: "t", tagId: nil, tagName: "arc")
        let withoutTag = entity(id: "n", tagId: nil, tagName: nil)
        let vm = await boundViewModel(blocks: [withTag, withoutTag], tags: [])

        let filtered = vm.filteredBlocks(
            debouncedSearchText: "",
            searchResults: [],
            selectedTagFilter: "untagged",
            hasTasksOnly: false,
            statusFilter: .all,
            sortField: .created,
            sortOrder: .newest,
            linkedPendingBlockIds: []
        )
        XCTAssertEqual(filtered.map(\.id), ["n"])
    }
}

private struct StubBlocksRepo: BlocksRepository, @unchecked Sendable {
    let snapshot: [BlockEntity]
    func observe() -> AsyncStream<[BlockEntity]> {
        AsyncStream { c in c.yield(snapshot); c.finish() }
    }
    func search(matching query: String) async throws -> [BlockEntity] { [] }
    func list() async throws -> [BlockEntity] { snapshot }
    func get(id: String) async throws -> BlockEntity? { snapshot.first { $0.id == id } }
    func create(title: String, markdown: String) async throws -> BlockEntity { throw RepositoryError.invalidInput }
    func update(id: String, markdown: String) async throws {}
    func delete(id: String) async throws {}
    func setTag(blockId: String, tagId: String?) async throws {}
    func setFullWidth(blockId: String, isFullWidth: Bool) async throws {}
    func setLayer(blockId: String, layer: BlockLayer) async throws {}
    func setType(blockId: String, type: BlockType) async throws {}
    func setStatus(blockId: String, status: String?) async throws {}
    func checkboxes(in blockId: String) async -> [BlockCheckbox] { [] }
    func toggleCheckbox(in blockId: String, lineNumber: Int) async throws {}
    func mutateFrontmatter(blockId: String, merge: [String: AnyCodableValue]) async throws -> Int { 0 }
    @MainActor func saveSync(id: String, markdown: String) -> Bool { false }
}

private struct StubTagsRepo: TagsRepository, @unchecked Sendable {
    let snapshot: [Tag]
    func observe() -> AsyncStream<[Tag]> {
        AsyncStream { c in c.yield(snapshot); c.finish() }
    }
    func list() async throws -> [Tag] { snapshot }
    func tag(for id: String) async throws -> Tag? { snapshot.first { $0.id == id } }
    func create(name: String, color: TagColor) async throws -> Tag { throw RepositoryError.invalidInput }
    func update(_ tag: Tag) async throws -> Tag { tag }
    func delete(id: String) async throws {}
}
