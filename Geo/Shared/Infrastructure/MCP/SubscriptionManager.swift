import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "SubscriptionManager")

enum SubscriptionKind: String, Sendable, Hashable {
    case task
    case block

    static func parse(_ raw: String) -> SubscriptionKind? {
        SubscriptionKind(rawValue: raw.lowercased())
    }

    static let all: Set<SubscriptionKind> = [.task, .block]
}

actor SubscriptionManager {
    typealias Notifier = @Sendable ([String: AnyCodableValue]) -> Void

    private static let isoFormatter = DateFormatters.iso8601

    private let blocks: any BlocksRepository
    private let tasks: any TasksRepository

    private var subscribers: [UUID: Set<SubscriptionKind>] = [:]
    private var notifiers: [UUID: Notifier] = [:]

    private var lastBlocks: [String: Date] = [:]
    private var lastTasks: [String: Date] = [:]
    private var blocksSeeded: Bool = false
    private var tasksSeeded: Bool = false

    private var blocksTask: Task<Void, Never>?
    private var tasksTask: Task<Void, Never>?

    init(blocks: any BlocksRepository, tasks: any TasksRepository) {
        self.blocks = blocks
        self.tasks = tasks
    }

    func start() {
        if blocksTask == nil {
            blocksTask = Task { [weak self] in
                guard let stream = await self?.blocksStream() else { return }
                for await entities in stream {
                    await self?.ingestBlocks(entities)
                }
            }
        }
        if tasksTask == nil {
            tasksTask = Task { [weak self] in
                guard let stream = await self?.tasksStream() else { return }
                for await items in stream {
                    await self?.ingestTasks(items)
                }
            }
        }
    }

    func stop() {
        blocksTask?.cancel()
        blocksTask = nil
        tasksTask?.cancel()
        tasksTask = nil
    }

    func subscribe(connectionId: UUID, kinds: Set<SubscriptionKind>, notify: @escaping Notifier) -> Set<SubscriptionKind> {
        let resolved = kinds.isEmpty ? SubscriptionKind.all : kinds
        let existing = subscribers[connectionId] ?? []
        subscribers[connectionId] = existing.union(resolved)
        notifiers[connectionId] = notify
        return resolved
    }

    func unsubscribe(connectionId: UUID, kinds: Set<SubscriptionKind>?) {
        guard let current = subscribers[connectionId] else { return }
        if let kinds, !kinds.isEmpty {
            let remaining = current.subtracting(kinds)
            if remaining.isEmpty {
                subscribers.removeValue(forKey: connectionId)
                notifiers.removeValue(forKey: connectionId)
            } else {
                subscribers[connectionId] = remaining
            }
        } else {
            subscribers.removeValue(forKey: connectionId)
            notifiers.removeValue(forKey: connectionId)
        }
    }

    func handleDisconnect(connectionId: UUID) {
        subscribers.removeValue(forKey: connectionId)
        notifiers.removeValue(forKey: connectionId)
    }

    func subscriptions(for connectionId: UUID) -> Set<SubscriptionKind> {
        subscribers[connectionId] ?? []
    }

    private func blocksStream() -> AsyncStream<[BlockEntity]> {
        blocks.observe()
    }

    private func tasksStream() -> AsyncStream<[TaskItem]> {
        tasks.observe()
    }

    private func ingestBlocks(_ entities: [BlockEntity]) {
        let snapshot = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0.lastEdited) })
        if !blocksSeeded {
            lastBlocks = snapshot
            blocksSeeded = true
            return
        }
        let diff = diffSnapshot(old: lastBlocks, new: snapshot)
        lastBlocks = snapshot
        for change in diff {
            broadcast(kind: .block, id: change.id, op: change.op, modifiedAt: change.modifiedAt)
        }
    }

    private func ingestTasks(_ items: [TaskItem]) {
        let snapshot = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.modifiedAt) })
        if !tasksSeeded {
            lastTasks = snapshot
            tasksSeeded = true
            return
        }
        let diff = diffSnapshot(old: lastTasks, new: snapshot)
        lastTasks = snapshot
        for change in diff {
            broadcast(kind: .task, id: change.id, op: change.op, modifiedAt: change.modifiedAt)
        }
    }

    private struct Change: Equatable {
        let id: String
        let op: String
        let modifiedAt: Date
    }

    private func diffSnapshot(old: [String: Date], new: [String: Date]) -> [Change] {
        var changes: [Change] = []
        for (id, modified) in new {
            if let previous = old[id] {
                if previous != modified {
                    changes.append(Change(id: id, op: "upsert", modifiedAt: modified))
                }
            } else {
                changes.append(Change(id: id, op: "upsert", modifiedAt: modified))
            }
        }
        for (id, previous) in old where new[id] == nil {
            changes.append(Change(id: id, op: "delete", modifiedAt: previous))
        }
        return changes
    }

    private func broadcast(kind: SubscriptionKind, id: String, op: String, modifiedAt: Date) {
        let params: [String: AnyCodableValue] = [
            "kind": .string(kind.rawValue),
            "id": .string(id),
            "op": .string(op),
            "modified_at": .string(Self.isoFormatter.string(from: modifiedAt)),
        ]
        for (connectionId, kinds) in subscribers where kinds.contains(kind) {
            notifiers[connectionId]?(params)
        }
    }
}

enum SubscriptionParams {
    static func parseKinds(_ params: [String: AnyCodableValue]?) -> Set<SubscriptionKind> {
        guard let params, case .array(let values)? = params["kinds"] else { return [] }
        var result: Set<SubscriptionKind> = []
        for value in values {
            if case .string(let raw) = value, let kind = SubscriptionKind.parse(raw) {
                result.insert(kind)
            }
        }
        return result
    }
}
