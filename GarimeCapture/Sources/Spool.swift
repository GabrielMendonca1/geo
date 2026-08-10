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

func spoolCapture(originalName: String, data: Data, ocrText: String, capturedAt: Date) -> URL? {
    let day = dayFolderName(for: capturedAt)
    guard isSafeDayFolder(day) else {
        logErr("refused spool: computed day folder is not safe (\(day))")
        return nil
    }
    let dayDir = spoolDir.appendingPathComponent(day, isDirectory: true)
    guard !isForbiddenPath(dayDir) else {
        logErr("refused spool: \(dayDir.path) is inside a forbidden vault root")
        return nil
    }
    do {
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
    } catch {
        logErr("failed to create spool day dir: \(error.localizedDescription)")
        return nil
    }

    let base = spoolBaseName(originalName: originalName, data: data, capturedAt: capturedAt)
    let imageName = "\(base).\(safeImageExtension(originalName))"
    let markdownName = "\(base).md"
    guard isSafeComponent(imageName), isSafeComponent(markdownName) else {
        logErr("refused spool: generated name failed the safety whitelist (\(imageName))")
        return nil
    }

    let imageURL = dayDir.appendingPathComponent(imageName, isDirectory: false)
    let markdownURL = dayDir.appendingPathComponent(markdownName, isDirectory: false)

    let frontmatter = """
    ---
    type: capture
    captured: \(ISO8601DateFormatter().string(from: capturedAt))
    source: "\(yamlEscape(originalName))"
    spooled_as: "\(imageName)"
    tags: [capture]
    ---

    \(ocrText)
    """
    guard writeAtomicGuarded(Data(frontmatter.utf8), to: markdownURL) else { return nil }
    guard writeAtomicGuarded(data, to: imageURL) else {
        try? fm.removeItem(at: markdownURL)
        return nil
    }
    guard syncToDisk(dayDir) else {
        try? fm.removeItem(at: markdownURL)
        try? fm.removeItem(at: imageURL)
        logErr("refused spool: could not fsync \(day); original left in place")
        return nil
    }
    return imageURL
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

func pruneEmptyDay(_ day: String) {
    let dayDir = spoolDir.appendingPathComponent(day, isDirectory: true)
    guard let entries = try? fm.contentsOfDirectory(atPath: dayDir.path), entries.isEmpty else { return }
    try? fm.removeItem(at: dayDir)
}
