import Foundation

protocol BlocksRepository: Sendable {
    func observe() -> AsyncStream<[BlockEntity]>
    func search(matching query: String) async throws -> [BlockEntity]
    func list() async throws -> [BlockEntity]
    func get(id: String) async throws -> BlockEntity?
    func create(title: String, markdown: String) async throws -> BlockEntity
    func create(title: String, markdown: String, folder: String?) async throws -> BlockEntity
    func move(id: String, toFolder folder: String?) async throws -> BlockEntity
    func createFolder(_ folder: String) async throws
    func listFolders() async -> [String]
    func update(id: String, markdown: String) async throws
    func delete(id: String) async throws
    func setTag(blockId: String, tagId: String?) async throws
    func setFullWidth(blockId: String, isFullWidth: Bool) async throws
    func setLayer(blockId: String, layer: BlockLayer) async throws
    func setType(blockId: String, type: BlockType) async throws
    func setStatus(blockId: String, status: String?) async throws
    func checkboxes(in blockId: String) async -> [BlockCheckbox]
    func toggleCheckbox(in blockId: String, lineNumber: Int) async throws
    func mutateFrontmatter(blockId: String, merge: [String: AnyCodableValue]) async throws -> Int
    @MainActor func saveSync(id: String, markdown: String) -> Bool
}

extension BlocksRepository {
    func get(id: String) async throws -> BlockEntity? {
        try await list().first(where: { $0.id == id })
    }

    func setStatus(blockId: String, status: BlockStatus) async throws {
        try await setStatus(blockId: blockId, status: status.rawValue)
    }

    func create(title: String, markdown: String, folder: String?) async throws -> BlockEntity {
        try await create(title: title, markdown: markdown)
    }

    func move(id: String, toFolder folder: String?) async throws -> BlockEntity {
        throw RepositoryError.notFound
    }

    func createFolder(_ folder: String) async throws {}

    func listFolders() async -> [String] { [] }
}
