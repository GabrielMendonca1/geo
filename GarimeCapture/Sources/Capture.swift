import AppKit
import Foundation
import CoreGraphics
import ImageIO
import Vision

let pollInterval: TimeInterval = 1
let stabilizeRetries = 10
let stabilizeDelay: TimeInterval = 0.3
let readRetries = 10
let readRetryDelay: TimeInterval = 0.2
let ocrTimeout: TimeInterval = 30
let registryRetentionSeconds: TimeInterval = 30 * 86_400
let registryMaxCount = 500
let spoolFailureLimit = 5

func screenshotsDirectory() -> URL {
    if let override = envValue("GARIME_WATCH_DIR") {
        let url = expandPath(override)
        if isForbiddenPath(url) {
            logErr("GARIME_WATCH_DIR points into a forbidden vault root (\(url.path)); ignoring")
        } else {
            return url
        }
    }
    let domain = "com.apple.screencapture" as CFString
    CFPreferencesAppSynchronize(domain)
    if let path = CFPreferencesCopyAppValue("location" as CFString, domain) as? String,
       !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        if isForbiddenPath(standardized) {
            logErr("screencapture location points into a forbidden vault root (\(standardized.path)); ignoring, falling back to Desktop")
        } else {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return standardized
            }
        }
    }
    return fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? homeDir
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
        guard !isForbiddenPath(url), let data = try? JSONEncoder().encode(entries) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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

@discardableResult
func writeClipboardPayload(imageData: Data, ocrText: String, fileURL: URL?) -> Int {
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
    if let fileURL {
        item.setString(fileURL.absoluteString, forType: .fileURL)
    }
    if !ocrText.isEmpty {
        item.setString(ocrText, forType: .string)
    }
    pasteboard.writeObjects([item])
    return pasteboard.changeCount
}

struct Candidate {
    let url: URL
    let key: String
    let timestamp: Date
}

let bootstrapURL = registryURL.deletingLastPathComponent()
    .appendingPathComponent("bootstrap", isDirectory: false)

let bootstrapCutoff: Date = {
    if let raw = try? String(contentsOf: bootstrapURL, encoding: .utf8),
       let epoch = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return Date(timeIntervalSince1970: epoch)
    }
    let now = Date()
    try? fm.createDirectory(at: bootstrapURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? String(Int(now.timeIntervalSince1970)).write(to: bootstrapURL, atomically: true, encoding: .utf8)
    logErr("first run: images predating \(ISO8601DateFormatter().string(from: now)) stay in place; everything newer is consumed no matter how long this daemon is down")
    return now
}()

var processing: Set<String> = []
var spoolFailures: [String: Int] = [:]
var loggedStale: Set<String> = []
let processed = ProcessedRegistry(url: registryURL)

func scan(directory: URL) {
    let cutoff = bootstrapCutoff
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
        let key = "\(file.lastPathComponent)|\(size)|\(Int(ts.timeIntervalSince1970))"
        if ts < cutoff {
            if !loggedStale.contains(key) {
                loggedStale.insert(key)
                logErr("skip \(file.lastPathComponent): predates this daemon's first run, left in place")
            }
            continue
        }
        if processing.contains(key) { continue }
        if processed.contains(key) { continue }
        if (spoolFailures[key] ?? 0) >= spoolFailureLimit { continue }
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

    let instantChange = writeClipboardPayload(imageData: data, ocrText: "", fileURL: nil)
    logErr("clipboard primed with \(candidate.url.lastPathComponent) (image only)")

    let text = runOCR(on: cgImage)
    guard let spooledURL = spoolCapture(
        originalName: candidate.url.lastPathComponent,
        data: data,
        ocrText: text,
        capturedAt: candidate.timestamp
    ) else {
        let attempts = (spoolFailures[candidate.key] ?? 0) + 1
        spoolFailures[candidate.key] = attempts
        logErr("spool failed for \(candidate.url.lastPathComponent) (attempt \(attempts)); original kept on disk")
        if attempts >= spoolFailureLimit {
            logErr("giving up on \(candidate.url.lastPathComponent) after \(attempts) spool failures")
        }
        return
    }

    processed.insert(candidate.key)
    spoolFailures[candidate.key] = nil
    try? fm.removeItem(at: candidate.url)

    if NSPasteboard.general.changeCount == instantChange {
        writeClipboardPayload(imageData: data, ocrText: text, fileURL: spooledURL)
    } else {
        logErr("clipboard changed during OCR; leaving user content untouched")
    }
    logErr("spooled \(candidate.url.lastPathComponent) as \(spooledURL.lastPathComponent) (\(text.count) chars OCR)")
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

func spoolAdd(paths: [String]) -> Bool {
    guard !paths.isEmpty else {
        logErr("spool-add: no paths given")
        return false
    }
    var ok = true
    for path in paths {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let data = readWithRetry(at: url) else {
            logErr("spool-add: unreadable \(path)")
            ok = false
            continue
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let capturedAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
        guard let spooled = spoolCapture(
            originalName: url.lastPathComponent,
            data: data,
            ocrText: "",
            capturedAt: capturedAt
        ) else {
            ok = false
            continue
        }
        try? fm.removeItem(at: url)
        logErr("spool-add: \(url.lastPathComponent) -> \(spooled.lastPathComponent)")
    }
    return ok
}
