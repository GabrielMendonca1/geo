import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "DayStore")

private let dayStoreNeedsReloadNotification = Notification.Name("DayStoreNeedsReload")

@MainActor
class DayStore: ObservableObject {
    static let shared = DayStore()

    @Published var days: [Day] = []

    private var daysById: [String: Int] = [:]

    private var reloadObserver: NSObjectProtocol?
    private let indexCoordinator: IndexCoordinator

    init(baseURL: URL? = nil, indexCoordinator: IndexCoordinator = .shared) {
        self.indexCoordinator = indexCoordinator

        // Day membership derives EXCLUSIVELY from the derived block_days table (inline
        // [[YYYY-MM-DD]] backlinks). The legacy days.json file is no longer read or written;
        // it survives on disk as an inert artifact.
        refreshFromDerive()
        reloadObserver = NotificationCenter.default.addObserver(
            forName: dayStoreNeedsReloadNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFromDerive()
        }
    }

    deinit {
        if let reloadObserver {
            NotificationCenter.default.removeObserver(reloadObserver)
        }
    }

    func day(for date: Date) -> Day? {
        let dayId = Day.idFromDate(date)
        guard let index = daysById[dayId] else { return nil }
        return days[index]
    }

    func day(for id: String) -> Day? {
        guard let index = daysById[id] else { return nil }
        return days[index]
    }

    private func rebuildDaysIndex() {
        daysById.removeAll(keepingCapacity: true)
        for (index, day) in days.enumerated() {
            daysById[day.id] = index
        }
    }

    func refreshFromDerive() {
        Task { [weak self, indexCoordinator] in
            let derived = await indexCoordinator.dayLinkMap()
            await MainActor.run {
                self?.applyDerived(derived)
            }
        }
    }

    // Day membership is REPLACED from the derived block_days map on every refresh, never
    // unioned with a prior (possibly stale) state. This is the sole populator of `days` and
    // correctly reflects removed [[date]] links because dayLinkMap() rebuilds the full map.
    private func applyDerived(_ derived: [String: [String]]) {
        var rebuilt: [Day] = []
        rebuilt.reserveCapacity(derived.count)
        for (dayId, blockIds) in derived {
            guard let date = DateFormatters.dayId.date(from: dayId) else { continue }
            var day = Day(date: date)
            day.blockIds = blockIds
            rebuilt.append(day)
        }
        rebuilt.sort { $0.date > $1.date }
        days = rebuilt
        rebuildDaysIndex()
    }
}
