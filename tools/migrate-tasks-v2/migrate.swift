#!/usr/bin/env swift
import Foundation

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let tasksDir = home.appendingPathComponent("Library/Application Support/Geo/Tasks", isDirectory: true)

guard fm.fileExists(atPath: tasksDir.path) else {
    print("✗ Tasks dir not found: \(tasksDir.path)")
    exit(1)
}

// Back up first.
let stamp: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}()
let backupDir = tasksDir.deletingLastPathComponent().appendingPathComponent("Tasks.bak-\(stamp)", isDirectory: true)
do {
    try fm.copyItem(at: tasksDir, to: backupDir)
    print("✓ Backup → \(backupDir.path)")
} catch {
    print("✗ Backup failed: \(error)")
    exit(1)
}

let isoIn: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
let isoInFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
func parseDate(_ s: Any?) -> Date? {
    guard let str = s as? String else { return nil }
    return isoIn.date(from: str) ?? isoInFractional.date(from: str)
}
func iso(_ d: Date) -> String { isoIn.string(from: d) }

let urls = (try? fm.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)) ?? []
let jsonURLs = urls.filter { $0.pathExtension == "json" }

var migrated = 0
var skippedAlreadyNew = 0
var failed: [(URL, String)] = []

for url in jsonURLs {
    guard let data = try? Data(contentsOf: url),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        failed.append((url, "unreadable"))
        continue
    }

    // Skip files already in the new shape.
    if obj["body"] is [String: Any], obj["reminders"] is [[String: Any]] {
        skippedAlreadyNew += 1
        continue
    }

    let kind = (obj["kind"] as? String) ?? "task"
    guard let startTime = parseDate(obj["startTime"]) else {
        failed.append((url, "missing startTime"))
        continue
    }
    let endTime = parseDate(obj["endTime"])
    let recurrenceObj = obj["recurrence"] as? [String: Any]
    let estimatedMinutes = obj["estimatedMinutes"] as? Int
    let completionHistoryStrs = (obj["completionHistory"] as? [String]) ?? []
    let completionHistory: [Date] = completionHistoryStrs.compactMap { isoIn.date(from: $0) ?? isoInFractional.date(from: $0) }

    var body: [String: Any] = [:]
    switch kind {
    case "event":
        body["kind"] = "event"
        body["start"] = iso(startTime)
        body["end"] = iso(endTime ?? startTime.addingTimeInterval(3600))
    case "habit":
        body["kind"] = "habit"
        body["rule"] = recurrenceObj ?? ["type": "daily"]
        body["timeOfDay"] = iso(startTime)
        body["occurrences"] = completionHistory.map(iso)
    case "milestone":
        body["kind"] = "milestone"
        let cal = Calendar.current
        body["target"] = iso(cal.startOfDay(for: startTime))
    default: // "task"
        body["kind"] = "task"
        body["due"] = iso(startTime)
        if let est = estimatedMinutes { body["estimatedMinutes"] = est }
    }

    // Reminders
    let firedSet = Set((obj["firedReminders"] as? [String]) ?? [])
    let reminderOffsets = (obj["reminders"] as? [String]) ?? []
    var newReminders: [[String: Any]] = reminderOffsets.map { off -> [String: Any] in
        [
            "id": UUID().uuidString,
            "trigger": ["kind": "offset", "offset": off],
            "fired": firedSet.contains(off),
        ]
    }
    if let snoozedStr = obj["snoozedUntil"] as? String, let snoozed = isoIn.date(from: snoozedStr) ?? isoInFractional.date(from: snoozedStr) {
        newReminders.append([
            "id": UUID().uuidString,
            "trigger": ["kind": "absolute", "date": iso(snoozed)],
            "fired": false,
        ])
    }

    // Build new object: keep stable fields, drop legacy, set body + reminders.
    let keepKeys: Set<String> = [
        "id", "title", "notes", "linkedBlockId", "status", "priority", "tagIds", "orderIndex",
        "estimatedMinutes", "createdAt", "modifiedAt",
    ]
    var out: [String: Any] = [:]
    for k in keepKeys {
        if let v = obj[k] { out[k] = v }
    }
    out["body"] = body
    out["reminders"] = newReminders

    do {
        let newData = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: url, options: .atomic)
        migrated += 1
    } catch {
        failed.append((url, "write failed: \(error)"))
    }
}

print("")
print("Migration summary")
print("  migrated:           \(migrated)")
print("  already-new:        \(skippedAlreadyNew)")
print("  failed:             \(failed.count)")
for (u, why) in failed {
    print("    - \(u.lastPathComponent): \(why)")
}
print("")
print("Backup is at:")
print("  \(backupDir.path)")
print("(Delete it once you've verified everything works.)")
