import Foundation
import Combine

protocol DayStoreAccess: Sendable {
    func observeDays() -> AsyncStream<[Day]>
    func day(for date: Date) -> Day?
}

private final class DayObservationBox: @unchecked Sendable {
    var cancellable: AnyCancellable?
}

final class LiveDayStoreAccess: DayStoreAccess, @unchecked Sendable {
    private let dayStore: DayStore

    init(dayStore: DayStore) {
        self.dayStore = dayStore
    }

    func observeDays() -> AsyncStream<[Day]> {
        AsyncStream { continuation in
            let box = DayObservationBox()
            let setupTask = Task { @MainActor [dayStore] in
                continuation.yield(dayStore.days)
                box.cancellable = dayStore.$days
                    .dropFirst()
                    .sink { days in
                        continuation.yield(days)
                    }
            }

            continuation.onTermination = { @Sendable _ in
                setupTask.cancel()
                Task { @MainActor in
                    box.cancellable?.cancel()
                    box.cancellable = nil
                }
            }
        }
    }

    func day(for date: Date) -> Day? {
        MainActor.assumeIsolated {
            dayStore.day(for: date)
        }
    }
}

struct DayStoreRepositoryAdapter: DayRepository, @unchecked Sendable {
    private let access: any DayStoreAccess

    init(dayStore: DayStore) {
        self.access = LiveDayStoreAccess(dayStore: dayStore)
    }

    init(access: any DayStoreAccess) {
        self.access = access
    }

    func observe() -> AsyncStream<[Day]> {
        access.observeDays()
    }

    func day(for date: Date) async -> Day? {
        await MainActor.run {
            access.day(for: date)
        }
    }
}
