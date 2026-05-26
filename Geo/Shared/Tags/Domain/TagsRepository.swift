import Foundation

protocol TagsRepository: Sendable {
    func observe() -> AsyncStream<[Tag]>
    func list() async throws -> [Tag]
    func tag(for id: String) async throws -> Tag?
    func create(name: String, color: TagColor) async throws -> Tag
    func update(_ tag: Tag) async throws -> Tag
    func delete(id: String) async throws
}
