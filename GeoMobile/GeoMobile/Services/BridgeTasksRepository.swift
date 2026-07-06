import Foundation
import GeoCore
import os

struct BridgeTasksRepository: TasksRepository {
    let client: BridgeClient

    private static let logger = Logger(subsystem: "com.gabrielmendonca.geomobile", category: "BridgeTasksRepository")

    init(client: BridgeClient = .shared) {
        self.client = client
    }

    private struct LenientTask: Decodable {
        let task: TaskItem?

        init(from decoder: Decoder) throws {
            task = try? TaskItem(from: decoder)
        }
    }

    func list() async throws -> [TaskItem] {
        let items: [LenientTask] = try await client.get("/tasks", decoder: BridgeClient.iso8601Decoder)
        let tasks = items.compactMap(\.task)
        if tasks.count != items.count {
            Self.logger.warning("Dropped \(items.count - tasks.count) of \(items.count) tasks that failed to decode")
        }
        return tasks
    }

    func observe() -> AsyncStream<[TaskItem]> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    if let tasks = try? await list() {
                        continuation.yield(tasks)
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    func completeTask(id: String) async throws -> TaskItem {
        try await client.post("/tasks/\(id)/complete", decoder: BridgeClient.iso8601Decoder)
    }

    @discardableResult
    func reopenTask(id: String) async throws -> TaskItem {
        try await client.post("/tasks/\(id)/reopen", decoder: BridgeClient.iso8601Decoder)
    }

    func importTask(_ task: TaskItem) async throws {
        throw BridgeError.unsupported("importTask")
    }

    func create(_ draft: TaskDraft) async throws -> TaskItem {
        try await create(TaskItem(
            id: UUID().uuidString,
            title: draft.title,
            linkedBlockId: draft.linkedBlockId,
            status: draft.status,
            priority: draft.priority,
            tagIds: draft.tagIds,
            orderIndex: draft.orderIndex,
            estimatedMinutes: draft.estimatedMinutes,
            body: draft.body,
            reminders: draft.reminders
        ))
    }

    func create(_ item: TaskItem) async throws -> TaskItem {
        _ = try await client.postData("/tasks", body: try BridgeClient.iso8601Encoder.encode(item))
        return item
    }

    func update(_ task: TaskItem) async throws {
        throw BridgeError.unsupported("update")
    }

    func delete(id: String) async throws {
        throw BridgeError.unsupported("delete")
    }
}
