import Foundation

protocol DayRepository: Sendable {
    func observe() -> AsyncStream<[Day]>
    func day(for date: Date) async -> Day?
}
