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
let ocrTimeout = envDouble("GARIME_OCR_TIMEOUT", 30)
let registryRetentionSeconds: TimeInterval = 30 * 86_400
let registryMaxCount = 500

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

enum OCROutcome {
    case text(String)
    case refused(String)
    case failed(String)
    case timedOut
}

func classifyOCRFailure(domain: String, code: Int, description: String) -> OCROutcome {
    guard domain == VNErrorDomain, code == VNErrorCode.invalidImage.rawValue else {
        return .failed("\(domain) \(code): \(description)")
    }
    return .refused(description)
}

func runOCR(on cgImage: CGImage) -> OCROutcome {
    let scaled = scaleIfNeeded(cgImage)
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var didFinish = false
    var result: OCROutcome = .timedOut

    let deliver: (OCROutcome) -> Void = { outcome in
        lock.lock()
        let already = didFinish
        didFinish = true
        if !already { result = outcome }
        lock.unlock()
        if already { return }
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
            deliver(.text(text))
        } catch {
            let ns = error as NSError
            deliver(classifyOCRFailure(domain: ns.domain, code: ns.code, description: ns.localizedDescription))
        }
    }

    _ = semaphore.wait(timeout: .now() + ocrTimeout)
    lock.lock()
    let timedOut = !didFinish
    didFinish = true
    let outcome = result
    lock.unlock()
    if timedOut {
        logErr("OCR timed out after \(ocrTimeout)s")
        return .timedOut
    }
    return outcome
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

let capturePasteboard: NSPasteboard = {
    guard let name = envValue("GARIME_PASTEBOARD_NAME") else { return .general }
    return NSPasteboard(name: NSPasteboard.Name(name))
}()

func clipboardFaultInjected(final: Bool) -> Bool {
    switch envValue("GARIME_FAIL_CLIPBOARD") {
    case "all": return true
    case "final": return final
    default: return false
    }
}

func writeClipboardPayload(imageData: Data, ocrText: String, fileURL: URL?) -> Int? {
    guard !clipboardFaultInjected(final: fileURL != nil) else {
        logErr("clipboard: refused by GARIME_FAIL_CLIPBOARD (test seam)")
        return nil
    }
    capturePasteboard.clearContents()
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
    guard capturePasteboard.writeObjects([item]) else {
        logErr("clipboard: the pasteboard server refused the write")
        return nil
    }
    return capturePasteboard.changeCount
}

func dumpClipboard() {
    for type in capturePasteboard.types ?? [] {
        print("type=\(type.rawValue)")
    }
    if let text = capturePasteboard.string(forType: .string) {
        print("string=\(text.replacingOccurrences(of: "\n", with: " "))")
    }
    if let file = capturePasteboard.string(forType: .fileURL) {
        print("fileURL=\(file)")
    }
    print("imageBytes=\(capturePasteboard.data(forType: .png)?.count ?? 0)")
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
var loggedStale: Set<String> = []
let processed = ProcessedRegistry(url: registryURL)
let failures = FailureLedger(url: failuresURL, listURL: strandedURL)

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
        if failures.isStranded(key) { continue }
        if failures.isBackingOff(key, now: Date()) { continue }
        candidates.append(Candidate(url: file, key: key, timestamp: ts))
    }

    candidates.sort { $0.timestamp < $1.timestamp }
    for candidate in candidates {
        processing.insert(candidate.key)
        process(candidate)
    }
}

func recordFailure(_ candidate: Candidate, _ reason: String) {
    let attempts = failures.record(
        key: candidate.key,
        name: candidate.url.lastPathComponent,
        reason: reason,
        now: Date()
    )
    logErr("\(reason) for \(candidate.url.lastPathComponent) (attempt \(attempts)); original kept on disk")
    if attempts >= captureFailureLimit {
        logErr("giving up on \(candidate.url.lastPathComponent) after \(attempts) failures; it is listed in \(strandedURL.path) so the watchdog stops restarting this daemon over it — a restart will not retry it, fix the cause and delete that entry (or wait \(Int(failureRetentionSeconds / 86_400)) days)")
    } else {
        logErr("next attempt for \(candidate.url.lastPathComponent) in \(Int(retryDelay(afterAttempts: attempts)))s")
    }
}

@discardableResult
func process(_ candidate: Candidate) -> Bool {
    defer { processing.remove(candidate.key) }

    guard let data = readWithRetry(at: candidate.url) else {
        logErr("skip \(candidate.url.lastPathComponent): file vanished or unreadable")
        return false
    }
    guard let cgImage = decodeCGImage(from: data) else {
        logErr("skip \(candidate.url.lastPathComponent): could not decode image")
        return false
    }

    let priorAttempts = failures.attempts(candidate.key)
    let primedChange: Int
    if priorAttempts > 0 {
        primedChange = capturePasteboard.changeCount
        logErr("retrying \(candidate.url.lastPathComponent) (attempt \(priorAttempts + 1)); the clipboard stays untouched until the OCR text is ready")
    } else {
        guard let primed = writeClipboardPayload(imageData: data, ocrText: "", fileURL: nil) else {
            recordFailure(candidate, "clipboard prime failed")
            return false
        }
        primedChange = primed
        logErr("clipboard primed with \(candidate.url.lastPathComponent) (image only)")
    }

    let text: String
    switch runOCR(on: cgImage) {
    case .text(let recognized):
        text = recognized
    case .refused(let reason):
        text = ""
        logErr("OCR refused \(candidate.url.lastPathComponent) (\(reason)); archiving the image with no text rather than stranding it")
    case .failed(let reason):
        recordFailure(candidate, "OCR failed (\(reason))")
        return false
    case .timedOut:
        recordFailure(candidate, "OCR timed out")
        return false
    }

    guard let archivedURL = archiveCapture(
        originalName: candidate.url.lastPathComponent,
        data: data,
        capturedAt: candidate.timestamp
    ) else {
        recordFailure(candidate, "archive failed")
        return false
    }

    if capturePasteboard.changeCount == primedChange {
        guard writeClipboardPayload(imageData: data, ocrText: text, fileURL: archivedURL) != nil else {
            recordFailure(candidate, "clipboard delivery failed")
            return false
        }
    } else {
        logErr("clipboard changed during OCR; user content wins and the \(text.count) chars of OCR are dropped")
    }

    processed.insert(candidate.key)
    failures.clear(candidate.key)
    try? fm.removeItem(at: candidate.url)
    logErr("archived \(candidate.url.lastPathComponent) as \(archivedURL.lastPathComponent) (\(text.count) chars OCR, clipboard only — never written to disk)")
    return true
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

func captureOnce(paths: [String]) -> Bool {
    guard !paths.isEmpty else {
        logErr("capture-once: no paths given")
        return false
    }
    var ok = true
    for path in paths {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
        let capturedAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
        let key = "\(url.lastPathComponent)|\(values?.fileSize ?? 0)|\(Int(capturedAt.timeIntervalSince1970))"
        processing.insert(key)
        if !process(Candidate(url: url, key: key, timestamp: capturedAt)) { ok = false }
    }
    return ok
}
