import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "DayMigration")

private let dayStoreNeedsReloadNotification = Notification.Name("DayStoreNeedsReload")

private struct Session: Codable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let duration: TimeInterval
    var blockIds: [String]
    var captureIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, duration, blockIds, captureIds
        case createdBlockIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decode(Date.self, forKey: .endTime)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        blockIds = try container.decodeIfPresent([String].self, forKey: .blockIds)
            ?? container.decodeIfPresent([String].self, forKey: .createdBlockIds)
            ?? []
        captureIds = try container.decodeIfPresent([UUID].self, forKey: .captureIds) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(duration, forKey: .duration)
        try container.encode(blockIds, forKey: .blockIds)
        try container.encode(captureIds, forKey: .captureIds)
    }
}

private struct OldDay: Codable {
    let id: String
    let date: Date
    let duration: TimeInterval?
    var blockIds: [String]
    var captureIds: [UUID]
}

private struct MigratedDay: Codable {
    let id: String
    let date: Date
    var blockIds: [String]
    var captureIds: [UUID]

    init(date: Date, blockIds: [String] = [], captureIds: [UUID] = []) {
        self.date = Calendar.current.startOfDay(for: date)
        self.id = Self.idFromDate(self.date)
        self.blockIds = blockIds
        self.captureIds = captureIds
    }

    static func idFromDate(_ date: Date) -> String {
        DateFormatters.dayId.string(from: date)
    }
}

@MainActor
class DayMigrationService {
    static let shared = DayMigrationService()

    private let userDefaults = UserDefaults.standard
    private let migrationKeyV1 = "DayMigrationV1Complete"
    private let migrationKeyV2 = "DayMigrationV2RemoveDuration"
    private let fileManager = FileManager.default

    private init() {}

    func migrateIfNeeded() {
        migrateV1IfNeeded()
        migrateV2IfNeeded()
    }

    private func migrateV1IfNeeded() {
        guard !userDefaults.bool(forKey: migrationKeyV1) else { return }

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.homeDirectoryForCurrentUser
        let sessionsURL = baseURL.appendingPathComponent("Geo/sessions.json")
        let daysURL = baseURL.appendingPathComponent("Geo/days.json")

        guard fileManager.fileExists(atPath: sessionsURL.path) else {
            userDefaults.set(true, forKey: migrationKeyV1)
            return
        }

        do {
            let backupURL = baseURL.appendingPathComponent("Geo/sessions.json.backup")
            try? fileManager.copyItem(at: sessionsURL, to: backupURL)

            let data = try Data(contentsOf: sessionsURL)
            let sessions = try JSONDecoder().decode([Session].self, from: data)

            var daysDictionary: [String: MigratedDay] = [:]

            for session in sessions {
                let dayDate = Calendar.current.startOfDay(for: session.startTime)
                let dayId = MigratedDay.idFromDate(dayDate)

                if var existingDay = daysDictionary[dayId] {
                    existingDay.blockIds.append(contentsOf: session.blockIds)
                    existingDay.captureIds.append(contentsOf: session.captureIds)

                    existingDay.blockIds = Array(Set(existingDay.blockIds))
                    existingDay.captureIds = Array(Set(existingDay.captureIds))

                    daysDictionary[dayId] = existingDay
                } else {
                    let newDay = MigratedDay(
                        date: dayDate,
                        blockIds: Array(Set(session.blockIds)),
                        captureIds: Array(Set(session.captureIds))
                    )
                    daysDictionary[dayId] = newDay
                }
            }

            var mergedById: [String: MigratedDay] = [:]
            if let existingData = try? Data(contentsOf: daysURL),
               let existingDays = try? JSONDecoder().decode([MigratedDay].self, from: existingData) {
                for existing in existingDays {
                    mergedById[existing.id] = existing
                }
            }

            for day in daysDictionary.values {
                if var existing = mergedById[day.id] {
                    existing.blockIds.append(contentsOf: day.blockIds)
                    existing.captureIds.append(contentsOf: day.captureIds)
                    existing.blockIds = Array(Set(existing.blockIds))
                    existing.captureIds = Array(Set(existing.captureIds))
                    mergedById[existing.id] = existing
                } else {
                    mergedById[day.id] = day
                }
            }

            let mergedDays = mergedById.values.sorted { $0.date > $1.date }
            try fileManager.createDirectory(at: daysURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let migratedData = try JSONEncoder().encode(mergedDays)
            try migratedData.write(to: daysURL, options: .atomic)
            NotificationCenter.default.post(name: dayStoreNeedsReloadNotification, object: nil)

            userDefaults.set(true, forKey: migrationKeyV1)
        } catch {
            logger.error("Day migration V1 failed: \(error.localizedDescription)")
        }
    }

    private func migrateV2IfNeeded() {
        guard !userDefaults.bool(forKey: migrationKeyV2) else { return }

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.homeDirectoryForCurrentUser
        let daysURL = baseURL.appendingPathComponent("Geo/days.json")

        guard fileManager.fileExists(atPath: daysURL.path) else {
            userDefaults.set(true, forKey: migrationKeyV2)
            return
        }

        do {
            let backupURL = baseURL.appendingPathComponent("Geo/days_v1.json.backup")
            try? fileManager.copyItem(at: daysURL, to: backupURL)

            let data = try Data(contentsOf: daysURL)
            let oldDays = try JSONDecoder().decode([OldDay].self, from: data)

            let newDays = oldDays.map { oldDay in
                MigratedDay(
                    date: oldDay.date,
                    blockIds: oldDay.blockIds,
                    captureIds: oldDay.captureIds
                )
            }

            let newData = try JSONEncoder().encode(newDays)
            try newData.write(to: daysURL, options: .atomic)
            NotificationCenter.default.post(name: dayStoreNeedsReloadNotification, object: nil)

            userDefaults.set(true, forKey: migrationKeyV2)
        } catch {
            logger.error("Day migration V2 failed: \(error.localizedDescription)")
        }
    }
}
