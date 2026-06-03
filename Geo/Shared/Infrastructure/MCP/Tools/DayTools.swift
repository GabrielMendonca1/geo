import Foundation
import os.log

enum DayTools {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "MCPDayTools")
    private static let validIdCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    private static func validateBlockId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 256 else { return false }
        if id.contains("\\") || id.contains("\0") || id.hasPrefix("/") {
            return false
        }
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        for segment in segments {
            if segment.isEmpty || segment == "." || segment == ".." { return false }
            if !segment.unicodeScalars.allSatisfy({ validIdCharacters.contains($0) }) { return false }
        }
        return true
    }

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
        [getToday(captures, indexCoordinator), getDay(captures, indexCoordinator), linkBlockToDay(blocks)]
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
                let (blockIds, captureCount) = await derivedBlockIds(days, date: date, dayId: dayId, indexCoordinator: indexCoordinator)
                let result: [String: AnyCodableValue] = [
                    "id": .string(dayId),
                    "block_ids": .array(blockIds.map { .string($0) }),
                    "capture_count": .int(captureCount),
                ]
                return .json(result)
            }
        ).registered
    }

    private static func getDay(_ days: any DayRepository, _ indexCoordinator: IndexCoordinator) -> MCPRegisteredTool {
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
                let (blockIds, captureCount) = await derivedBlockIds(days, date: date, dayId: dayId, indexCoordinator: indexCoordinator)
                let result: [String: AnyCodableValue] = [
                    "id": .string(dayId),
                    "block_ids": .array(blockIds.map { .string($0) }),
                    "capture_count": .int(captureCount),
                ]
                return .json(result)
            }
        ).registered
    }

    private static func linkBlockToDay(_ blocks: any BlocksRepository) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "link_block_to_day",
            description: "Link a block to a specific day by inserting an inline [[YYYY-MM-DD]] backlink into its body (Obsidian Daily Notes convention).",
            schema: JSONSchemaObject(properties: [
                "block_id": .string("Block ID (filename or relative path)"),
                "date": .string("Date in YYYY-MM-DD format"),
            ], required: ["block_id", "date"]),
            handler: { args in
                guard let blockId = args["block_id"]?.stringValue,
                      let dateStr = args["date"]?.stringValue else {
                    return .error("Missing required parameters: block_id, date")
                }
                guard validateBlockId(blockId) else {
                    return .error("invalid block id")
                }
                guard let date = DateFormatters.dayId.date(from: dateStr) else {
                    return .error("Invalid date format. Use YYYY-MM-DD")
                }
                switch try await AgentAuthorization.authorizeWrite(.linkToDay, id: blockId, in: blocks) {
                case .ok: break
                case .denied(let result): return result
                }
                let dayId = DateFormatters.dayId.string(from: date)
                do {
                    try await blocks.linkToDay(blockId: blockId, dayId: dayId)
                } catch {
                    return .error("failed to link block to day")
                }
                return .json(["success": true])
            }
        ).registered
    }
}
