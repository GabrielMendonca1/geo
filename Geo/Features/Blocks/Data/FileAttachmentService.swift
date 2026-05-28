import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "Attachments")

private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
private let maxFilenameByteLength = 200

private var defaultBlocksDirectory: URL {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fm.homeDirectoryForCurrentUser
    return base.appendingPathComponent("Geo/Blocks", isDirectory: true)
}

func blockAttachmentNamespace(for blockURL: URL) -> (root: URL, folderName: String) {
    let blocksRoot = defaultBlocksDirectory
    let basePath = blocksRoot.standardizedFileURL.path
    let stemPath = blockURL.deletingPathExtension().standardizedFileURL.path
    if stemPath.hasPrefix(basePath + "/") {
        return (blocksRoot, String(stemPath.dropFirst(basePath.count + 1)))
    }
    return (blockURL.deletingLastPathComponent(), blockURL.deletingPathExtension().lastPathComponent)
}

func sanitizeAttachmentFilename(_ raw: String) -> String {
    let scalars = raw.unicodeScalars.filter { scalar in
        if scalar.value < 0x20 { return false }
        if scalar.value == 0x7F { return false }
        if (0x202A...0x202E).contains(scalar.value) { return false }
        if (0x2066...0x2069).contains(scalar.value) { return false }
        return true
    }
    var cleaned = String(String.UnicodeScalarView(scalars))
    cleaned = cleaned
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: "\\", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    let (rawStem, rawExt) = splitStemAndExtension(cleaned)
    var stem = collapseDotRuns(rawStem)
    var ext = collapseDotRuns(rawExt)
    stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    ext = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". "))

    let result: String
    if stem.isEmpty && ext.isEmpty {
        result = "attachment.bin"
    } else if stem.isEmpty {
        result = "attachment.\(ext)"
    } else if ext.isEmpty {
        result = stem
    } else {
        result = "\(stem).\(ext)"
    }

    return truncateFilenameIfNeeded(result, maxBytes: maxFilenameByteLength)
}

private func splitStemAndExtension(_ name: String) -> (String, String) {
    guard let dot = name.lastIndex(of: ".") else { return (name, "") }
    let stem = String(name[..<dot])
    let ext = String(name[name.index(after: dot)...])
    return (stem, ext)
}

private func collapseDotRuns(_ s: String) -> String {
    var out = ""
    var run = 0
    for ch in s {
        if ch == "." {
            run += 1
        } else {
            if run == 1 { out.append(".") }
            else if run >= 2 { out.append("_") }
            run = 0
            out.append(ch)
        }
    }
    if run == 1 { out.append(".") }
    else if run >= 2 { out.append("_") }
    return out
}

private func truncateFilenameIfNeeded(_ name: String, maxBytes: Int) -> String {
    guard name.utf8.count > maxBytes else { return name }
    let url = URL(fileURLWithPath: name)
    let ext = url.pathExtension
    let stem = url.deletingPathExtension().lastPathComponent
    let extWithDot = ext.isEmpty ? "" : ".\(ext)"
    let extBytes = extWithDot.utf8.count
    let allowedStemBytes = max(1, maxBytes - extBytes)
    var truncated = stem
    while truncated.utf8.count > allowedStemBytes && !truncated.isEmpty {
        truncated.removeLast()
    }
    if truncated.isEmpty { truncated = "attachment" }
    return truncated + extWithDot
}

struct FileAttachmentService: AttachmentService, @unchecked Sendable {
    private let fileManager: FileManager
    private let maxDimension: CGFloat = 1920
    private let jpegQuality: CGFloat = 0.8

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func ensureDirectory(at directory: URL) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            return true
        } catch {
            logger.error("Failed to create directory: \(directory.path, privacy: .public) error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func copyAttachment(from source: URL, to directory: URL) -> URL? {
        let safeName = sanitizeAttachmentFilename(source.lastPathComponent)
        let destination = uniqueURL(for: safeName, in: directory)
        do {
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
            return destination
        } catch {
            logger.error("Failed to copy attachment: \(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: destination)
            return nil
        }
    }

    func saveImageData(_ data: Data, extension ext: String, to directory: URL) -> URL? {
        guard !data.isEmpty else {
            logger.error("saveImageData called with empty data")
            return nil
        }

        let timestamp = fileTimestampString()
        let filename = sanitizeAttachmentFilename("image-\(timestamp).\(ext)")
        let destination = uniqueURL(for: filename, in: directory)

        do {
            try data.write(to: destination, options: .atomic)
            let exists = fileManager.fileExists(atPath: destination.path)
            logger.info("Image saved: \(destination.path, privacy: .public) exists=\(exists, privacy: .public) size=\(data.count, privacy: .public)")
            return exists ? destination : nil
        } catch {
            logger.error("Failed to write image data: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func saveImage(_ image: NSImage, to directory: URL) -> URL? {
        let scaled = scaledIfNeeded(image)
        guard let bitmapRep = bitmapRepresentation(from: scaled) else {
            logger.error("saveImage: failed to get bitmap representation")
            return nil
        }

        let useAlpha = bitmapRep.hasAlpha
        let data: Data?
        let ext: String

        if useAlpha {
            data = bitmapRep.representation(using: .png, properties: [:])
            ext = "png"
        } else {
            data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
            ext = "jpg"
        }

        guard let imageData = data, !imageData.isEmpty else {
            logger.error("saveImage: failed to encode bitmap as \(ext, privacy: .public)")
            return nil
        }

        return saveImageData(imageData, extension: ext, to: directory)
    }

    func uniqueURL(for fileName: String, in directory: URL) -> URL {
        let baseURL = directory.appendingPathComponent(fileName)
        if reserveFile(at: baseURL) {
            return baseURL
        }

        let baseName = baseURL.deletingPathExtension().lastPathComponent
        let fileExtension = baseURL.pathExtension
        var attempt = 1

        while true {
            let candidateName = fileExtension.isEmpty ? "\(baseName)-\(attempt)" : "\(baseName)-\(attempt).\(fileExtension)"
            let candidate = directory.appendingPathComponent(candidateName)
            if reserveFile(at: candidate) {
                return candidate
            }
            attempt += 1
            if attempt > 10_000 { return candidate }
        }
    }

    private func reserveFile(at url: URL) -> Bool {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }

    func deleteAttachmentsDirectory(for blockURL: URL) {
        let blocksDirectory = blockURL.deletingLastPathComponent()
        let blockFolderName = blockURL.deletingPathExtension().lastPathComponent
        let attachmentsDir = blocksDirectory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(blockFolderName, isDirectory: true)
        try? fileManager.removeItem(at: attachmentsDir)
    }

    func deleteAttachment(relativePath: String, baseDirectory: URL) {
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        let fileURL = baseDirectory.appendingPathComponent(decoded)
        try? fileManager.removeItem(at: fileURL)
    }

    private func scaledIfNeeded(_ image: NSImage) -> NSImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else { return image }

        let scale = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = NSSize(width: round(size.width * scale), height: round(size.height * scale))

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }

    private func bitmapRepresentation(from image: NSImage) -> NSBitmapImageRep? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           rep.colorSpaceName == .deviceRGB || rep.colorSpaceName == .calibratedRGB {
            return rep
        }

        let width = Int(size.width)
        let height = Int(size.height)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        return rep
    }

    private func fileTimestampString() -> String {
        let interval = Date().timeIntervalSince1970
        let seconds = Int(interval)
        let millis = Int((interval - Double(seconds)) * 1000)
        let base = DateFormatters.fileTimestamp.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return "\(base)-\(String(format: "%03d", millis))"
    }
}

func isValidPNGData(_ data: Data) -> Bool {
    guard data.count >= pngSignature.count + 8 else { return false }
    for (i, byte) in pngSignature.enumerated() where data[i] != byte {
        return false
    }
    return true
}
