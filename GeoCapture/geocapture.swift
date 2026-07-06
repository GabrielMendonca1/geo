import AppKit
import Foundation
import CoreGraphics
import ImageIO
import Vision

func logErr(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
}

let fm = FileManager.default
let vaultCapturesDir = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("GeoVault", isDirectory: true)
    .appendingPathComponent("Captures", isDirectory: true)
let processedRegistryURL = vaultCapturesDir.appendingPathComponent(".processed.json", isDirectory: false)

let pollInterval: TimeInterval = 5
let recencyWindow: TimeInterval = 15
let stabilizeRetries = 10
let stabilizeDelay: TimeInterval = 0.3
let readRetries = 10
let readRetryDelay: TimeInterval = 0.2
let ocrTimeout: TimeInterval = 30
let registryRetentionSeconds: TimeInterval = 30 * 86_400
let registryMaxCount = 500

let forbiddenOldVault = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Geo", isDirectory: true)
    .standardizedFileURL.path

func screenshotsDirectory() -> URL {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    task.arguments = ["read", "com.apple.screencapture", "location"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            if standardized.path.hasPrefix(forbiddenOldVault) {
                logErr("screencapture location points into retired Geo vault (\(standardized.path)); ignoring, falling back to Desktop")
            } else {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                    return standardized
                }
            }
        }
    } catch {
        logErr("failed to read screencapture location: \(error.localizedDescription)")
    }
    return fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
}

final class ProcessedRegistry {
    private let url: URL
    private var entries: [String: TimeInterval]

    init(url: URL) {
        self.url = url
        self.entries = Self.load(from: url)
    }

    func contains(_ key: String) -> Bool { entries[key] != nil }

    func insert(_ key: String) {
        entries[key] = Date().timeIntervalSince1970
        prune()
        persist()
    }

    private func prune() {
        let cutoff = Date().timeIntervalSince1970 - registryRetentionSeconds
        entries = entries.filter { $0.value >= cutoff }
        if entries.count > registryMaxCount {
            let sorted = entries.sorted { $0.value > $1.value }.prefix(registryMaxCount)
            entries = Dictionary(uniqueKeysWithValues: Array(sorted))
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func load(from url: URL) -> [String: TimeInterval] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else { return [:] }
        return dict
    }
}

func makeOCRRequest() -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest { _, _ in }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.preferBackgroundProcessing = false
    if #available(macOS 14, *) {
        request.revision = VNRecognizeTextRequestRevision3
    } else {
        request.revision = VNRecognizeTextRequest.currentRevision
    }
    let preferred = Locale.preferredLanguages.compactMap { identifier -> String? in
        let locale = Locale(identifier: identifier)
        guard let language = locale.language.languageCode?.identifier else { return nil }
        if let region = locale.region?.identifier {
            return "\(language)-\(region)"
        }
        return language
    }
    request.recognitionLanguages = preferred.isEmpty ? ["en-US"] : preferred
    return request
}

func scaleIfNeeded(_ cgImage: CGImage, maxDimension: CGFloat = 3000) -> CGImage {
    let w = CGFloat(cgImage.width)
    let h = CGFloat(cgImage.height)
    let maxSide = max(w, h)
    guard maxSide > maxDimension else { return cgImage }
    let scale = maxDimension / maxSide
    let newW = Int((w * scale).rounded())
    let newH = Int((h * scale).rounded())
    let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(
        data: nil,
        width: newW,
        height: newH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else { return cgImage }
    ctx.interpolationQuality = .high
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
    return ctx.makeImage() ?? cgImage
}

func runOCR(on cgImage: CGImage) -> String {
    let scaled = scaleIfNeeded(cgImage)
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var didFinish = false
    var result = ""

    let deliver: (String) -> Void = { text in
        lock.lock()
        let already = didFinish
        didFinish = true
        lock.unlock()
        if already { return }
        result = text
        semaphore.signal()
    }

    let request = makeOCRRequest()
    DispatchQueue.global(qos: .userInitiated).async {
        let handler = VNImageRequestHandler(cgImage: scaled, options: [:])
        do {
            try handler.perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            deliver(text)
        } catch {
            logErr("OCR failed: \(error.localizedDescription)")
            deliver("")
        }
    }

    _ = semaphore.wait(timeout: .now() + ocrTimeout)
    lock.lock()
    let timedOut = !didFinish
    didFinish = true
    lock.unlock()
    if timedOut {
        logErr("OCR timed out after \(Int(ocrTimeout))s")
        return ""
    }
    return result
}

func waitForStableFile(at url: URL) -> Data? {
    var lastSize: Int = -1
    for attempt in 0..<stabilizeRetries {
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int else { return nil }
        if size == lastSize && size > 0 {
            return try? Data(contentsOf: url, options: .uncached)
        }
        lastSize = size
        if attempt < stabilizeRetries - 1 {
            Thread.sleep(forTimeInterval: stabilizeDelay)
        }
    }
    return try? Data(contentsOf: url, options: .uncached)
}

func readWithRetry(at url: URL) -> Data? {
    for attempt in 0..<readRetries {
        guard fm.fileExists(atPath: url.path) else { return nil }
        if let data = waitForStableFile(at: url), !data.isEmpty {
            return data
        }
        if attempt < readRetries - 1 {
            Thread.sleep(forTimeInterval: readRetryDelay)
        }
    }
    return nil
}

func decodeCGImage(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func dayFolderName(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
}

func yamlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "\"", with: "\\\"")
}

func writeClipboardPayload(imageData: Data, ocrText: String, fileURL: URL) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    if let image = NSImage(data: imageData), let tiff = image.tiffRepresentation {
        item.setData(tiff, forType: .tiff)
        if let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
    }
    item.setString(fileURL.absoluteString, forType: .fileURL)
    if !ocrText.isEmpty {
        item.setString(ocrText, forType: .string)
    }
    pasteboard.writeObjects([item])
}

func persistCapture(originalName: String, data: Data, ocrText: String, capturedAt: Date) -> URL? {
    let dayDir = vaultCapturesDir.appendingPathComponent(dayFolderName(for: capturedAt), isDirectory: true)
    do {
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
    } catch {
        logErr("failed to create day dir: \(error.localizedDescription)")
        return nil
    }

    let baseName = (originalName as NSString).deletingPathExtension
    let ext = (originalName as NSString).pathExtension.isEmpty ? "png" : (originalName as NSString).pathExtension
    var pngURL = dayDir.appendingPathComponent("\(baseName).\(ext)", isDirectory: false)
    var mdURL = dayDir.appendingPathComponent("\(baseName).md", isDirectory: false)
    var suffix = 1
    while fm.fileExists(atPath: pngURL.path) || fm.fileExists(atPath: mdURL.path) {
        pngURL = dayDir.appendingPathComponent("\(baseName)-\(suffix).\(ext)", isDirectory: false)
        mdURL = dayDir.appendingPathComponent("\(baseName)-\(suffix).md", isDirectory: false)
        suffix += 1
    }

    do {
        try data.write(to: pngURL, options: .atomic)
    } catch {
        logErr("failed to write image: \(error.localizedDescription)")
        return nil
    }

    let iso = ISO8601DateFormatter().string(from: capturedAt)
    let frontmatter = """
    ---
    type: capture
    captured: \(iso)
    source: "\(yamlEscape(originalName))"
    tags: [capture]
    ---

    \(ocrText)
    """
    do {
        try frontmatter.write(to: mdURL, atomically: true, encoding: .utf8)
    } catch {
        logErr("failed to write markdown: \(error.localizedDescription)")
    }
    return pngURL
}

struct Candidate {
    let url: URL
    let key: String
    let timestamp: Date
}

var processing: Set<String> = []
let processed = ProcessedRegistry(url: processedRegistryURL)
let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif"]

func scan(directory: URL) {
    let now = Date()
    let cutoff = now.addingTimeInterval(-recencyWindow)
    let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isDirectoryKey, .fileSizeKey]

    let files: [URL]
    do {
        files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
    } catch {
        logErr("scan failed for \(directory.path): \(error.localizedDescription)")
        return
    }

    var candidates: [Candidate] = []
    for file in files {
        if file.lastPathComponent.hasPrefix(".") { continue }
        if !imageExtensions.contains(file.pathExtension.lowercased()) { continue }
        guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
        if values.isDirectory == true { continue }
        let size = values.fileSize ?? 0
        if size <= 0 { continue }
        let ts = values.creationDate ?? values.contentModificationDate ?? .distantPast
        if ts < cutoff { continue }
        let key = "\(file.lastPathComponent)|\(size)|\(Int(ts.timeIntervalSince1970))"
        if processing.contains(key) { continue }
        if processed.contains(key) { continue }
        candidates.append(Candidate(url: file, key: key, timestamp: ts))
    }

    candidates.sort { $0.timestamp < $1.timestamp }
    for candidate in candidates {
        processing.insert(candidate.key)
        process(candidate)
    }
}

func process(_ candidate: Candidate) {
    defer { processing.remove(candidate.key) }

    guard let data = readWithRetry(at: candidate.url) else {
        logErr("skip \(candidate.url.lastPathComponent): file vanished or unreadable")
        return
    }
    guard let cgImage = decodeCGImage(from: data) else {
        logErr("skip \(candidate.url.lastPathComponent): could not decode image")
        return
    }

    let text = runOCR(on: cgImage)
    let storedURL = persistCapture(originalName: candidate.url.lastPathComponent, data: data, ocrText: text, capturedAt: candidate.timestamp)
    processed.insert(candidate.key)
    try? fm.removeItem(at: candidate.url)
    writeClipboardPayload(imageData: data, ocrText: text, fileURL: storedURL ?? candidate.url)
    logErr("processed \(candidate.url.lastPathComponent) (\(text.count) chars OCR)")
}

func warmUpOCR() {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let dummy = ctx.makeImage() else { return }
    logErr("warming up Vision text recognition model...")
    let start = Date()
    _ = runOCR(on: dummy)
    logErr("Vision model warm (\(Int(Date().timeIntervalSince(start)))s)")
}

try? fm.createDirectory(at: vaultCapturesDir, withIntermediateDirectories: true)
warmUpOCR()
logErr("geocapture starting, watching \(screenshotsDirectory().path)")

while true {
    let dir = screenshotsDirectory()
    scan(directory: dir)
    Thread.sleep(forTimeInterval: pollInterval)
}
