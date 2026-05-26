import Foundation

protocol ShelfRepository: Sendable {
    func observe() -> AsyncStream<[ShelfItem]>
    func add(_ item: ShelfItem) async throws
    func remove(id: UUID) async throws
    func clear() async throws
    func setVisible(_ visible: Bool) async throws
}
