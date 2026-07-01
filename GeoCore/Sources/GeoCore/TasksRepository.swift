import Foundation

public protocol TasksRepository: Sendable {
    func observe() -> AsyncStream<[TaskItem]>
    func importTask(_ task: TaskItem) async throws
    func list() async throws -> [TaskItem]
    func create(_ draft: TaskDraft) async throws -> TaskItem
    func update(_ task: TaskItem) async throws
    func delete(id: String) async throws
}
