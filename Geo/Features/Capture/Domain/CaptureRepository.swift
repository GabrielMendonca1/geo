import Foundation

protocol CaptureRepository: Sendable {
    func observe() -> AsyncStream<[CaptureItem]>
    func list() async throws -> [CaptureItem]
    func append(_ item: CaptureItem) async throws
    func linkToDay(captureId: UUID, dayId: String) async throws
    func delete(ids: Set<UUID>) async throws
}
