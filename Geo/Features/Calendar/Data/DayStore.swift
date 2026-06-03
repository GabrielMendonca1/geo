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

    func addOrUpdateDay(_ day: Day) {
        if let index = daysById[day.id] {
            days[index] = day
        } else {
            days.append(day)
            days.sort { $0.date > $1.date }
            rebuildDaysIndex()
        }
        persistInBackground()
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

    func addBlockToDay(date: Date, blockId: String) {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        let dayId = Day.idFromDate(normalizedDate)
        if let index = daysById[dayId] {
            guard !days[index].blockIds.contains(blockId) else { return }
            days[index].blockIds.append(blockId)
            persistInBackground()
        } else {
            var day = Day(date: normalizedDate)
            day.blockIds.append(blockId)
            days.append(day)
            days.sort { $0.date > $1.date }
            rebuildDaysIndex()
            persistInBackground()
        }
    }

    func addCaptureToDay(date: Date, captureId: UUID) {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        let dayId = Day.idFromDate(normalizedDate)
        if let index = daysById[dayId] {
            guard !days[index].captureIds.contains(captureId) else { return }
            days[index].captureIds.append(captureId)
            persistInBackground()
        } else {
            var day = Day(date: normalizedDate)
            day.captureIds.append(captureId)
            days.append(day)
            days.sort { $0.date > $1.date }
            rebuildDaysIndex()
            persistInBackground()
        }
    }

    func deleteDay(id: String) {
        days.removeAll { $0.id == id }
        rebuildDaysIndex()
        persistInBackground()
    }

    private func rebuildDaysIndex() {
        daysById.removeAll(keepingCapacity: true)
        for (index, day) in days.enumerated() {
            daysById[day.id] = index
        }
    }

    private func persistInBackground() {
        let snapshot = days
        let url = daysURL
        queue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error("Failed to save days: \(error)")
            }
        }
    }

    private func loadDays() {
        guard fileManager.fileExists(atPath: daysURL.path) else { return }

        do {
            let data = try Data(contentsOf: daysURL)
            let loadedDays = try JSONDecoder().decode([Day].self, from: data)
            days = loadedDays.sorted { $0.date > $1.date }
            rebuildDaysIndex()
        } catch {
            logger.error("Failed to load days: \(error)")
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

    private func applyDerived(_ derived: [String: [String]]) {
        for (dayId, blockIds) in derived {
            guard let date = DateFormatters.dayId.date(from: dayId) else { continue }
            if let index = daysById[dayId] {
                var existing = Set(days[index].blockIds)
                var merged = days[index].blockIds
                for blockId in blockIds where existing.insert(blockId).inserted {
                    merged.append(blockId)
                }
                if merged.count != days[index].blockIds.count {
                    days[index].blockIds = merged
                }
            } else {
                var day = Day(date: date)
                day.blockIds = blockIds
                days.append(day)
                days.sort { $0.date > $1.date }
                rebuildDaysIndex()
            }
        }
    }
}
