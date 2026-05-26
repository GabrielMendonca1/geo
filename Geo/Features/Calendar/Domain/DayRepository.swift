import Foundation

protocol DayRepository: Sendable {
    func observe() -> AsyncStream<[Day]>
    func day(for date: Date) async -> Day?
    func addOrUpdateDay(_ day: Day) async throws
    func addBlockToDay(date: Date, blockId: String) async throws
    func addCaptureToDay(date: Date, captureId: UUID) async throws
    func deleteDay(date: Date) async throws
}
