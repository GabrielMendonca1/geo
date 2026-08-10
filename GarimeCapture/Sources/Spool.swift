import Foundation

let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif"]

func dayFolderName(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
}

func compactStamp(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
}

func safeImageExtension(_ originalName: String) -> String {
    let ext = (originalName as NSString).pathExtension.lowercased()
    return imageExtensions.contains(ext) ? ext : "png"
}

func spoolBaseName(originalName: String, data: Data, capturedAt: Date) -> String {
    let digest = shortDigest([Data(originalName.utf8), data])
    return "\(compactStamp(for: capturedAt))-\(digest)"
}

func yamlEscape(_ value: String) -> String {
    let flattened = value
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return String(flattened.prefix(200))
}

func writeAtomicGuarded(_ data: Data, to url: URL) -> Bool {
    guard !isForbiddenPath(url) else {
        logErr("refused write into forbidden vault root: \(url.path)")
        return false
    }
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        logErr("failed to write \(url.lastPathComponent): \(error.localizedDescription)")
        return false
    }
    guard syncToDisk(url) else {
        try? fm.removeItem(at: url)
        return false
    }
    return true
}

func dayDirectory(under root: URL, day: String, label: String) -> URL? {
    guard isSafeDayFolder(day) else {
        logErr("refused \(label): computed day folder is not safe (\(day))")
        return nil
    }
    let dayDir = root.appendingPathComponent(day, isDirectory: true)
    guard !isForbiddenPath(dayDir) else {
        logErr("refused \(label): \(dayDir.path) is inside a forbidden vault root")
        return nil
    }
    do {
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
    } catch {
        logErr("failed to create \(label) day dir \(day): \(error.localizedDescription)")
        return nil
    }
    return dayDir
}

func spoolCapture(originalName: String, data: Data, ocrText: String, capturedAt: Date) -> URL? {
    let day = dayFolderName(for: capturedAt)
    let archiveDay = dayFolderName(for: nowDate())
    guard let archiveDayDir = dayDirectory(under: archiveDir, day: archiveDay, label: "archive"),
          let spoolDayDir = dayDirectory(under: spoolDir, day: day, label: "spool") else { return nil }

    let base = spoolBaseName(originalName: originalName, data: data, capturedAt: capturedAt)
    let imageName = "\(base).\(safeImageExtension(originalName))"
    let markdownName = "\(base).md"
    guard isSafeComponent(imageName), isSafeComponent(markdownName) else {
        logErr("refused spool: generated name failed the safety whitelist (\(imageName))")
        return nil
    }

    let imageURL = archiveDayDir.appendingPathComponent(imageName, isDirectory: false)
    let markdownURL = spoolDayDir.appendingPathComponent(markdownName, isDirectory: false)

    let frontmatter = """
    ---
    type: capture
    captured: \(ISO8601DateFormatter().string(from: capturedAt))
    source: "\(yamlEscape(originalName))"
    spooled_as: "\(imageName)"
    archived: "\(archiveDay)"
    tags: [capture]
    ---

    \(ocrText)
    """
    guard writeAtomicGuarded(data, to: imageURL) else { return nil }
    guard syncToDisk(archiveDayDir) else {
        logErr("refused spool: could not fsync archive/\(archiveDay); original left in place")
        return nil
    }
    guard writeAtomicGuarded(Data(frontmatter.utf8), to: markdownURL) else {
        logErr("refused spool: markdown failed for \(markdownName); archived image kept for the retry, original left in place")
        return nil
    }
    guard syncToDisk(spoolDayDir) else {
        try? fm.removeItem(at: markdownURL)
        logErr("refused spool: could not fsync spool/\(day); original left in place")
        return nil
    }
    return imageURL
}

func archivedCopy(named name: String) -> URL? {
    for day in archiveDays() {
        let candidate = archiveDir.appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        if fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}

func adoptSpooledImages(files: [URL]) {
    let day = dayFolderName(for: nowDate())
    guard let dayDir = dayDirectory(under: archiveDir, day: day, label: "archive") else { return }
    var moved = 0
    for file in files {
        let name = file.lastPathComponent
        let dest = dayDir.appendingPathComponent(name, isDirectory: false)
        if let existing = archivedCopy(named: name) {
            let existingDay = existing.deletingLastPathComponent().lastPathComponent
            let sourceSize = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
            let destSize = (try? fm.attributesOfItem(atPath: existing.path)[.size] as? Int) ?? nil
            guard let sourceSize, let destSize, sourceSize == destSize else {
                logErr("archive: \(name) already exists in archive/\(existingDay) with different bytes; leaving the spool copy in place, never uploading it")
                continue
            }
            try? fm.removeItem(at: file)
            logErr("archive: \(name) was already archived in \(existingDay); dropped the duplicate spool copy")
            continue
        }
        do {
            try fm.moveItem(at: file, to: dest)
            moved += 1
            logErr("archive: adopted legacy spool image \(name) into archive/\(day); it is never uploaded")
        } catch {
            logErr("archive: could not move \(name) into archive/\(day): \(error.localizedDescription); left in the spool, never uploaded")
        }
    }
    if moved > 0 { _ = syncToDisk(dayDir) }
}

func spoolDays() -> [String] {
    guard let entries = try? fm.contentsOfDirectory(atPath: spoolDir.path) else { return [] }
    return entries.filter(isSafeDayFolder).sorted()
}

func spoolFiles(day: String) -> [URL] {
    let dayDir = spoolDir.appendingPathComponent(day, isDirectory: true)
    guard let entries = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    var result: [URL] = []
    for entry in entries {
        let name = entry.lastPathComponent
        guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        guard isSpoolArtifact(name), isSafeComponent(name) else {
            logErr("spool: skipping foreign file in \(day): \(name)")
            continue
        }
        result.append(entry)
    }
    return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func spoolStats() -> (files: Int, oldestAge: Int) {
    var count = 0
    var oldest: Date?
    let now = Date()
    for day in spoolDays() {
        for file in spoolFiles(day: day) {
            count += 1
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let stamp = values?.contentModificationDate ?? values?.creationDate ?? now
            if oldest == nil || stamp < oldest! { oldest = stamp }
        }
    }
    guard let oldest else { return (0, 0) }
    return (count, max(0, Int(now.timeIntervalSince(oldest))))
}

func isMarkdown(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "md"
}

func spoolPending() -> (markdown: Int, images: Int) {
    var markdown = 0
    var images = 0
    for day in spoolDays() {
        let dayDir = spoolDir.appendingPathComponent(day, isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if isSpoolArtifact(entry.lastPathComponent), isMarkdown(entry) { markdown += 1 } else { images += 1 }
        }
    }
    return (markdown, images)
}

func pruneEmptyDay(_ day: String) {
    let dayDir = spoolDir.appendingPathComponent(day, isDirectory: true)
    guard let entries = try? fm.contentsOfDirectory(atPath: dayDir.path), entries.isEmpty else { return }
    try? fm.removeItem(at: dayDir)
}
