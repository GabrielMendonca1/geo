import XCTest
@testable import Geo

final class SubscriptionManagerTests: XCTestCase {
    func testSubscribeWithExplicitKinds() async {
        let manager = SubscriptionManager(blocks: FakeBlocksRepo(), tasks: FakeTasksRepo())
        let id = UUID()
        let resolved = await manager.subscribe(connectionId: id, kinds: [.task]) { _ in }
        XCTAssertEqual(resolved, [.task])
        let stored = await manager.subscriptions(for: id)
        XCTAssertEqual(stored, [.task])
    }

    func testSubscribeWithEmptyKindsSubscribesToAll() async {
        let manager = SubscriptionManager(blocks: FakeBlocksRepo(), tasks: FakeTasksRepo())
        let id = UUID()
        let resolved = await manager.subscribe(connectionId: id, kinds: []) { _ in }
        XCTAssertEqual(resolved, Set<SubscriptionKind>([.task, .block]))
        let stored = await manager.subscriptions(for: id)
        XCTAssertEqual(stored, Set<SubscriptionKind>([.task, .block]))
    }

    func testUnsubscribeRemovesKind() async {
        let manager = SubscriptionManager(blocks: FakeBlocksRepo(), tasks: FakeTasksRepo())
        let id = UUID()
        _ = await manager.subscribe(connectionId: id, kinds: []) { _ in }
        await manager.unsubscribe(connectionId: id, kinds: [.task])
        let stored = await manager.subscriptions(for: id)
        XCTAssertEqual(stored, [.block])
    }

    func testUnsubscribeWithEmptyOrNilRemovesAll() async {
        let manager = SubscriptionManager(blocks: FakeBlocksRepo(), tasks: FakeTasksRepo())
        let id = UUID()
        _ = await manager.subscribe(connectionId: id, kinds: []) { _ in }
        await manager.unsubscribe(connectionId: id, kinds: nil)
        let stored = await manager.subscriptions(for: id)
        XCTAssertTrue(stored.isEmpty)
    }

    func testHandleDisconnectClearsSubscription() async {
        let manager = SubscriptionManager(blocks: FakeBlocksRepo(), tasks: FakeTasksRepo())
        let id = UUID()
        _ = await manager.subscribe(connectionId: id, kinds: [.block]) { _ in }
        await manager.handleDisconnect(connectionId: id)
        let stored = await manager.subscriptions(for: id)
        XCTAssertTrue(stored.isEmpty)
    }
}

private final class FakeBlocksRepo: BlocksRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[BlockEntity]> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
    func search(matching query: String) async throws -> [BlockEntity] { [] }
    func list() async throws -> [BlockEntity] { [] }
    func create(title: String, markdown: String) async throws -> BlockEntity {
        throw RepositoryError.invalidInput
    }
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

private final class FakeTasksRepo: TasksRepository, @unchecked Sendable {
    func observe() -> AsyncStream<[TaskItem]> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
    func importTask(_ task: TaskItem) async throws {}
    func list() async throws -> [TaskItem] { [] }
    func create(_ draft: TaskDraft) async throws -> TaskItem {
        throw RepositoryError.invalidInput
    }
    func update(_ task: TaskItem) async throws {}
    func delete(id: String) async throws {}
}
