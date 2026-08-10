import Foundation

enum Retention {
    static let days = envInt("GARIME_ARCHIVE_RETENTION_DAYS", 30)
    static let interval = envDouble("GARIME_RETENTION_INTERVAL", 21_600)
}

func archiveEntries() -> [String] {
    guard let entries = try? fm.contentsOfDirectory(atPath: archiveDir.path) else { return [] }
    return entries.sorted()
}

func archiveDays() -> [String] {
    archiveEntries().filter(isSafeDayFolder)
}

func purgableArchiveDay(_ day: String) -> URL? {
    guard isSafeDayFolder(day) else { return nil }
    let dayDir = archiveDir.appendingPathComponent(day, isDirectory: true)
    guard !isForbiddenPath(dayDir) else {
        logErr("retention: refusing to purge \(dayDir.path) — inside a forbidden vault root")
        return nil
    }
    guard let type = try? fm.attributesOfItem(atPath: dayDir.path)[.type] as? FileAttributeType,
          type == .typeDirectory else {
        logErr("retention: \(day) is not a plain directory; leaving it in place")
        return nil
    }
    let base = archiveDir.resolvingSymlinksInPath().standardizedFileURL.path
    let resolved = dayDir.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolved.hasPrefix(base + "/") else {
        logErr("retention: \(day) resolves outside the archive (\(resolved)); leaving it in place")
        return nil
    }
    return dayDir
}

func isRegularFile(_ url: URL) -> Bool {
    guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return false }
    return (attributes[.type] as? FileAttributeType) == .typeRegular
}

func archiveFileCount(_ dayDir: URL) -> Int {
    guard let entries = try? fm.contentsOfDirectory(atPath: dayDir.path) else { return 0 }
    return entries.filter { isRegularFile(dayDir.appendingPathComponent($0, isDirectory: false)) }.count
}

func purgeArchiveDay(_ dayDir: URL, day: String) -> (files: Int, removedDay: Bool) {
    guard let entries = try? fm.contentsOfDirectory(atPath: dayDir.path) else { return (0, false) }
    var deleted = 0
    for name in entries {
        let entry = dayDir.appendingPathComponent(name, isDirectory: false)
        guard isRegularFile(entry), isSpoolArtifact(name), isSafeComponent(name) else {
            logErr("retention: keeping archive/\(day)/\(name) — not an artifact this daemon generated")
            continue
        }
        do {
            try fm.removeItem(at: entry)
            deleted += 1
        } catch {
            logErr("retention: could not purge archive/\(day)/\(name): \(error.localizedDescription)")
        }
    }
    guard (try? fm.contentsOfDirectory(atPath: dayDir.path))?.isEmpty == true else {
        logErr("retention: kept archive/\(day) — \(deleted) artifact(s) purged, foreign content remains")
        return (deleted, false)
    }
    do {
        try fm.removeItem(at: dayDir)
        return (deleted, true)
    } catch {
        logErr("retention: could not remove the empty archive/\(day): \(error.localizedDescription)")
        return (deleted, false)
    }
}

func archiveDayAgeInDays(_ day: String, now: Date) -> Int {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    guard let date = formatter.date(from: day) else { return 0 }
    return max(0, Int(now.timeIntervalSince(date) / 86_400))
}

struct RetentionStatus {
    var lastPass = 0
    var archiveDays = 0
    var archiveFiles = 0
    var archiveOldestAgeDays = 0
    var pendingMarkdown = 0
    var pendingImages = 0
    var purgedDaysTotal = 0
    var purgedFilesTotal = 0
}

func loadRetentionStatus() -> RetentionStatus? {
    guard let raw = try? String(contentsOf: retentionStatusURL, encoding: .utf8) else { return nil }
    var fields: [String: Int] = [:]
    for line in raw.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, let value = Int(parts[1]) else { continue }
        fields[String(parts[0])] = value
    }
    var status = RetentionStatus()
    status.lastPass = fields["last_pass"] ?? 0
    status.archiveDays = fields["archive_days"] ?? 0
    status.archiveFiles = fields["archive_files"] ?? 0
    status.archiveOldestAgeDays = fields["archive_oldest_age_days"] ?? 0
    status.pendingMarkdown = fields["pending_md"] ?? 0
    status.pendingImages = fields["pending_images"] ?? 0
    status.purgedDaysTotal = fields["purged_days_total"] ?? 0
    status.purgedFilesTotal = fields["purged_files_total"] ?? 0
    return status
}

func writeRetentionStatus(_ status: RetentionStatus) {
    let body = """
    last_pass=\(status.lastPass)
    archive_days=\(status.archiveDays)
    archive_files=\(status.archiveFiles)
    archive_oldest_age_days=\(status.archiveOldestAgeDays)
    pending_md=\(status.pendingMarkdown)
    pending_images=\(status.pendingImages)
    purged_days_total=\(status.purgedDaysTotal)
    purged_files_total=\(status.purgedFilesTotal)
    """
    try? fm.createDirectory(at: statusDir, withIntermediateDirectories: true)
    try? (body + "\n").write(to: retentionStatusURL, atomically: true, encoding: .utf8)
}

@discardableResult
func retentionPass() -> Bool {
    let now = nowDate()
    let cutoff = dayFolderName(for: now.addingTimeInterval(-Double(Retention.days) * 86_400))
    guard isSafeDayFolder(cutoff) else {
        logErr("retention: refusing to purge — computed cutoff is not a safe day folder (\(cutoff))")
        return false
    }

    var purgedDays = 0
    var purgedFiles = 0
    for entry in archiveEntries() {
        guard isSafeDayFolder(entry) else {
            logErr("retention: skipping foreign entry in the archive: \(entry)")
            continue
        }
        guard entry < cutoff else { continue }
        guard let dayDir = purgableArchiveDay(entry) else { continue }
        let result = purgeArchiveDay(dayDir, day: entry)
        purgedFiles += result.files
        if result.removedDay {
            purgedDays += 1
            logErr("retention: purged archive/\(entry) (\(result.files) file(s), older than \(Retention.days)d cutoff \(cutoff))")
        }
    }

    let remaining = archiveDays()
    var status = loadRetentionStatus() ?? RetentionStatus()
    status.lastPass = Int(Date().timeIntervalSince1970)
    status.archiveDays = remaining.count
    status.archiveFiles = remaining.reduce(0) { total, day in
        total + archiveFileCount(archiveDir.appendingPathComponent(day, isDirectory: true))
    }
    status.archiveOldestAgeDays = remaining.first.map { archiveDayAgeInDays($0, now: now) } ?? 0
    let pending = spoolPending()
    status.pendingMarkdown = pending.markdown
    status.pendingImages = pending.images
    status.purgedDaysTotal += purgedDays
    status.purgedFilesTotal += purgedFiles
    writeRetentionStatus(status)

    if purgedDays > 0 {
        logErr("retention: \(purgedDays) day(s) purged, \(status.archiveDays) day(s) / \(status.archiveFiles) image(s) kept")
    }
    if pending.images > 0 {
        logErr("retention: \(pending.images) file(s) stuck in the spool that are never uploaded — they are not archived either")
    }
    return true
}

func retentionLoop() {
    logErr("retention: archive \(archiveDir.path), keeping \(Retention.days) day(s), pass every \(Int(Retention.interval))s")
    while true {
        beat(retentionHeartbeat)
        retentionPass()
        sleepBeating(Retention.interval, heartbeat: retentionHeartbeat)
    }
}
