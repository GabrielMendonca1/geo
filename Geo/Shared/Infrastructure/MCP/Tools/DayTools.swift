import Foundation
import os.log

enum DayTools {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "MCPDayTools")
    private static var dailyDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Geo/Blocks/Daily", isDirectory: true)
    }

    private static func ensureDailyNote(dayId: String) {
        let dir = dailyDirectory
        let url = dir.appendingPathComponent("\(dayId).md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "# \(dayId)\n".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to create daily note for \(dayId, privacy: .public): \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func derivedBlockIds(
        dayId: String,
        captures: (any CaptureRepository)?,
        indexCoordinator: IndexCoordinator
    ) async -> (blockIds: [String], captureCount: Int) {
        // Block membership derives PURELY from block_days (inline [[date]] backlinks).
        let blockIds = await indexCoordinator.blockIds(matchingDay: dayId)
        // Captures are unioned via CaptureItem.dayId, never days.json.
        let captureCount: Int
        if let captures {
            let all = (try? await captures.list()) ?? []
            captureCount = all.filter { $0.dayId == dayId }.count
        } else {
            captureCount = 0
        }
        return (blockIds, captureCount)
    }

    static func register(
        blocks: any BlocksRepository,
        captures: (any CaptureRepository)? = nil,
        indexCoordinator: IndexCoordinator = .shared
    ) -> [MCPRegisteredTool] {
        [getToday(captures, indexCoordinator), getDay(captures, indexCoordinator)]
    }

    private static func getToday(_ captures: (any CaptureRepository)?, _ indexCoordinator: IndexCoordinator) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "get_today",
            description: "Get today's day record with linked blocks (derived from inline [[date]] backlinks) and captures.",
            schema: JSONSchemaObject(),
            handler: { _ in
                let date = Date()
                let dayId = Day.idFromDate(date)
                ensureDailyNote(dayId: dayId)
                let (blockIds, captureCount) = await derivedBlockIds(dayId: dayId, captures: captures, indexCoordinator: indexCoordinator)
                let result: [String: AnyCodableValue] = [
                    "id": .string(dayId),
                    "block_ids": .array(blockIds.map { .string($0) }),
                    "capture_count": .int(captureCount),
                ]
                return .json(result)
            }
        ).registered
    }

    private static func getDay(_ captures: (any CaptureRepository)?, _ indexCoordinator: IndexCoordinator) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "get_day",
            description: "Get a specific day's record. Blocks are derived from inline [[date]] backlinks, unioned with captures.",
            schema: JSONSchemaObject(properties: [
                "date": .string("Date in YYYY-MM-DD format"),
            ], required: ["date"]),
            handler: { args in
                guard let dateStr = args["date"]?.stringValue else {
                    return .error("Missing required parameter: date")
                }
                guard let date = DateFormatters.dayId.date(from: dateStr) else {
                    return .error("Invalid date format. Use YYYY-MM-DD")
                }
                let dayId = DateFormatters.dayId.string(from: date)
                ensureDailyNote(dayId: dayId)
                let (blockIds, captureCount) = await derivedBlockIds(dayId: dayId, captures: captures, indexCoordinator: indexCoordinator)
                let result: [String: AnyCodableValue] = [
                    "id": .string(dayId),
                    "block_ids": .array(blockIds.map { .string($0) }),
                    "capture_count": .int(captureCount),
                ]
                return .json(result)
            }
        ).registered
    }

}
