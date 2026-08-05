import Foundation
import GeoCore
import os

struct BridgeTasksRepository: TasksRepository {
    let client: any BridgeAPI

    private static let logger = Logger(subsystem: "com.gabrielmendonca.garime", category: "BridgeTasksRepository")

    init(client: any BridgeAPI = BridgeClient.shared) {
        self.client = client
    }

    private struct LenientTask: Decodable {
        let task: TaskItem?
        let failure: String?

        init(from decoder: Decoder) throws {
            do {
                task = try TaskItem(from: decoder)
                failure = nil
            } catch {
                task = nil
                failure = String(describing: error)
            }
        }
    }

    struct DecodedTasks {
        let tasks: [TaskItem]
        let droppedCount: Int
        let dropReasons: [String]
    }

    func list() async throws -> [TaskItem] {
        let data = try await client.getData(BridgeEndpoint.tasksList.path)
        let result = try Self.decodeTasks(from: data)
        TasksCache.save(data)
        return result.tasks
    }

    func cached() -> (tasks: [TaskItem], fetchedAt: Date)? {
        guard let entry = TasksCache.load(),
              let result = try? Self.decodeTasks(from: entry.payload)
        else { return nil }
        return (result.tasks, entry.fetchedAt)
    }

    static func decodeTasks(from data: Data) throws -> DecodedTasks {
        let items = try BridgeClient.iso8601Decoder.decode([LenientTask].self, from: data)
        let tasks = items.compactMap(\.task)
        let reasons = items.compactMap(\.failure)
        if !reasons.isEmpty {
            logger.warning("Dropped \(reasons.count, privacy: .public) of \(items.count, privacy: .public) tasks: \(reasons.joined(separator: " | "), privacy: .public)")
        }
        return DecodedTasks(tasks: tasks, droppedCount: reasons.count, dropReasons: reasons)
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
        try await client.post(
            BridgeEndpoint.taskComplete(id: id).path,
            decoder: BridgeClient.iso8601Decoder
        )
    }

    @discardableResult
    func reopenTask(id: String) async throws -> TaskItem {
        try await client.post(
            BridgeEndpoint.taskReopen(id: id).path,
            decoder: BridgeClient.iso8601Decoder
        )
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
        _ = try await client.postData(
            BridgeEndpoint.tasksCreate.path,
            body: try BridgeClient.iso8601Encoder.encode(item)
        )
        return item
    }

    func update(_ task: TaskItem) async throws {
        throw BridgeError.unsupported("update")
    }

    func delete(id: String) async throws {
        _ = try await client.delete(BridgeEndpoint.taskDelete(id: id).path)
    }
}
