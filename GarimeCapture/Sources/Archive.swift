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

func archiveBaseName(originalName: String, data: Data, capturedAt: Date) -> String {
    let digest = shortDigest([Data(originalName.utf8), data])
    return "\(compactStamp(for: capturedAt))-\(digest)"
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

func archiveCapture(originalName: String, data: Data, capturedAt: Date) -> URL? {
    let archiveDay = dayFolderName(for: nowDate())
    guard let archiveDayDir = dayDirectory(under: archiveDir, day: archiveDay, label: "archive") else { return nil }

    let base = archiveBaseName(originalName: originalName, data: data, capturedAt: capturedAt)
    let imageName = "\(base).\(safeImageExtension(originalName))"
    guard isSafeComponent(imageName), isArchiveArtifact(imageName) else {
        logErr("refused archive: generated name failed the safety whitelist (\(imageName))")
        return nil
    }

    let imageURL = archiveDayDir.appendingPathComponent(imageName, isDirectory: false)
    guard writeAtomicGuarded(data, to: imageURL) else { return nil }
    guard syncToDisk(archiveDayDir) else {
        logErr("refused archive: could not fsync archive/\(archiveDay); original left in place")
        return nil
    }
    return imageURL
}

func legacySpoolFileCount() -> Int {
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: legacySpoolDir.path, isDirectory: &isDir), isDir.boolValue else { return 0 }
    guard let walker = fm.enumerator(at: legacySpoolDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
    var count = 0
    for case let entry as URL in walker {
        guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        count += 1
    }
    return count
}

func warnLegacySpool() {
    let count = legacySpoolFileCount()
    guard count > 0 else { return }
    logErr("ERROR: \(count) file(s) left in \(legacySpoolDir.path) by the retired upload stage — this daemon has no network and will never send, read, move or delete them; move or remove them by hand")
}
