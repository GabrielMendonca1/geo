import Cocoa
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "ScreenshotWatcher")

struct ScreenshotFolderPreference {
    private static let key = "screenshotFolder.path"
    private static let defaults = UserDefaults.standard

    static var current: URL {
        if let path = defaults.string(forKey: key) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url.standardizedFileURL
            }
        }

        if let systemPath = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !systemPath.isEmpty {
            let url = URL(fileURLWithPath: systemPath, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url.standardizedFileURL
            }
        }

        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ??
            FileManager.default.homeDirectoryForCurrentUser
    }

    static func save(_ url: URL) {
        defaults.set(url.path, forKey: key)
    }
}

private final class ProcessedRegistry {
    private let url: URL
    private var entries: [String: TimeInterval]

    init(url: URL) {
        self.url = url
        self.entries = Self.load(from: url)
    }

    func contains(_ key: String) -> Bool { entries[key] != nil }

    func insert(_ key: String) {
        entries[key] = Date().timeIntervalSince1970
        persist()
    }

    func prune(olderThan seconds: TimeInterval, maxCount: Int) {
        let cutoff = Date().timeIntervalSince1970 - seconds
        entries = entries.filter { $0.value >= cutoff }
        if entries.count > maxCount {
            let sorted = entries.sorted { $0.value > $1.value }.prefix(maxCount)
            entries = Dictionary(uniqueKeysWithValues: Array(sorted))
        }
        persist()
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

class ScreenshotWatcher: ObservableObject {

    private let logStore: LogStore
    private let ocrService: OCRService
    private let capturesDirectory: URL
    private let processedRegistryURL: URL

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var screenshotsDirectory: URL
    private let scanQueue = DispatchQueue(label: "com.geo.screenshotwatcher.scan", qos: .userInitiated)
    private var safetyPollTimer: DispatchSourceTimer?
    private var cleanupTimer: DispatchSourceTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var processing: Set<String> = []
    private lazy var processed: ProcessedRegistry = ProcessedRegistry(url: processedRegistryURL)

    private let recencyWindow: TimeInterval = 10
    private let minimumScanInterval: TimeInterval = 0.2
    private let safetyPollInterval: TimeInterval = 2.5
    private let cleanupCheckInterval: TimeInterval = 86_400
    private let captureRetentionDays: Int = 30
    private let maxReadRetries = 60

    private var lastScanTime: Date = .distantPast

    private let stateLock = NSLock()
    private var _lastProcessedURL: URL?
    private var _lastProcessedTime: Date = .distantPast
    private var _lastOCRText: String?
    private var _lastCapturedImage: NSImage?

    var lastProcessedURL: URL? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastProcessedURL
    }
    var lastProcessedTime: Date {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastProcessedTime
    }
    var lastOCRText: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastOCRText
    }
    var lastCapturedImage: NSImage? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastCapturedImage
    }

    init(logStore: LogStore, ocrService: OCRService = .shared) {
        self.logStore = logStore
        self.ocrService = ocrService
        self.capturesDirectory = logStore.capturesDirectory
        self.processedRegistryURL = logStore.capturesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".processed-screenshots.json", isDirectory: false)
        let directory = ScreenshotFolderPreference.current
        self.screenshotsDirectory = directory
        observeWorkspace()
        configureWatcher(for: directory)
    }

    deinit {
        stopWatching()
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    func startWatching() {
        if source == nil, fileDescriptor != -1 {
            let newSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: scanQueue
            )

            newSource.setEventHandler { [weak self] in
                self?.detectNewFiles()
            }

            let capturedFD = fileDescriptor
            newSource.setCancelHandler {
                if capturedFD != -1 {
                    close(capturedFD)
                }
            }

            source = newSource
            newSource.resume()

            scanQueue.async { [weak self] in
                self?.lastScanTime = .distantPast
                self?.detectNewFiles()
            }
        }
        startSafetyPoll()
        startCleanupTimer()
    }

    func stopWatching() {
        safetyPollTimer?.cancel()
        safetyPollTimer = nil
        cleanupTimer?.cancel()
        cleanupTimer = nil
        if let src = source {
            src.cancel()
            source = nil
            fileDescriptor = -1
        } else if fileDescriptor != -1 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    func updateWatchDirectory(to url: URL) {
        ScreenshotFolderPreference.save(url)
        configureWatcher(for: url)
    }

    func forceScan() {
        scanQueue.async { [weak self] in
            self?.lastScanTime = .distantPast
            self?.detectNewFiles()
        }
    }

    private func configureWatcher(for directory: URL) {
        stopWatching()
        screenshotsDirectory = directory.standardizedFileURL

        let fileManager = FileManager.default
        let targetPath = directory.path
        if fileManager.isReadableFile(atPath: targetPath) {
            fileDescriptor = open(targetPath, O_EVTONLY)
            if fileDescriptor != -1 {
                startWatching()
                if source != nil { return }
            }
        }

        if let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first,
           desktop.standardizedFileURL != directory.standardizedFileURL {
            screenshotsDirectory = desktop.standardizedFileURL
            fileDescriptor = open(desktop.path, O_EVTONLY)
            if fileDescriptor != -1 {
                startWatching()
                return
            }
        }

        startSafetyPoll()
        startCleanupTimer()
    }

    private func startSafetyPoll() {
        safetyPollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: scanQueue)
        timer.schedule(deadline: .now() + safetyPollInterval, repeating: safetyPollInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.reconcileWatchedDirectoryIfNeeded()
            self.detectNewFiles()
        }
        safetyPollTimer = timer
        timer.resume()
    }

    private func startCleanupTimer() {
        cleanupTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: scanQueue)
        timer.schedule(deadline: .now() + 30, repeating: cleanupCheckInterval, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in
            self?.performCleanup()
        }
        cleanupTimer = timer
        timer.resume()
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        let wake = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.forceScan()
        }
        workspaceObservers.append(wake)
    }

    private func reconcileWatchedDirectoryIfNeeded() {
        let preferred = ScreenshotFolderPreference.current.standardizedFileURL
        let dirAlive = FileManager.default.fileExists(atPath: screenshotsDirectory.path)
        let needsReopen = source == nil || fileDescriptor == -1 || !dirAlive
        if preferred != screenshotsDirectory.standardizedFileURL || needsReopen {
            DispatchQueue.main.async { [weak self] in
                self?.configureWatcher(for: preferred)
            }
        }
    }

    private func detectNewFiles() {
        let now = Date()
        if now.timeIntervalSince(lastScanTime) < minimumScanInterval {
            return
        }
        lastScanTime = now

        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isDirectoryKey, .fileSizeKey]
        let keySet = Set(keys)
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif"]
        let scanCutoff = now.addingTimeInterval(-recencyWindow)

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: screenshotsDirectory, includingPropertiesForKeys: keys)
        } catch {
            handleScanFailure(error: error)
            return
        }

        struct Candidate {
            let url: URL
            let key: String
            let timestamp: Date
        }
        var candidates: [Candidate] = []

        for file in files {
            if file.lastPathComponent.hasPrefix(".") { continue }
            if !imageExtensions.contains(file.pathExtension.lowercased()) { continue }
            guard let values = try? file.resourceValues(forKeys: keySet) else { continue }
            if values.isDirectory == true { continue }
            let size = values.fileSize ?? 0
            if size <= 0 { continue }
            let ts = values.creationDate ?? values.contentModificationDate ?? .distantPast
            if ts < scanCutoff { continue }
            let key = "\(file.lastPathComponent)|\(size)|\(Int(ts.timeIntervalSince1970))"
            if processing.contains(key) { continue }
            if processed.contains(key) { continue }
            candidates.append(Candidate(url: file, key: key, timestamp: ts))
        }

        candidates.sort { $0.timestamp < $1.timestamp }

        for c in candidates {
            processing.insert(c.key)
            snapshotAndProcess(url: c.url, key: c.key)
        }
    }

    private func handleScanFailure(error: Error) {
        let exists = FileManager.default.fileExists(atPath: screenshotsDirectory.path)
        if !exists {
            logger.warning("Watched directory \(self.screenshotsDirectory.path, privacy: .public) is gone; falling back to Desktop")
            if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
                DispatchQueue.main.async { [weak self] in
                    self?.configureWatcher(for: desktop)
                }
            }
        } else {
            logger.error("Scan error: \(error.localizedDescription)")
        }
    }

    private func snapshotAndProcess(url: URL, key: String, attempt: Int = 0) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if attempt < 5 {
                scanQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.snapshotAndProcess(url: url, key: key, attempt: attempt + 1)
                }
                return
            }
            processing.remove(key)
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .uncached)
        } catch {
            if attempt >= maxReadRetries {
                logger.warning("Failed to snapshot \(url.lastPathComponent, privacy: .public) after \(self.maxReadRetries) attempts")
                processing.remove(key)
                return
            }
            scanQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.snapshotAndProcess(url: url, key: key, attempt: attempt + 1)
            }
            return
        }

        guard !data.isEmpty, let image = NSImage(data: data), image.isValid, image.size.width > 0 else {
            if attempt >= maxReadRetries {
                logger.warning("Invalid image data for \(url.lastPathComponent, privacy: .public)")
                processing.remove(key)
                return
            }
            scanQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.snapshotAndProcess(url: url, key: key, attempt: attempt + 1)
            }
            return
        }

        process(image: image, data: data, originalURL: url, key: key)
    }

    private func process(image: NSImage, data: Data, originalURL: URL, key: String) {
        let storedURL = persistToCaptures(data: data, originalURL: originalURL)
        let effectiveURL = storedURL ?? originalURL
        let now = Date()

        stateLock.lock()
        _lastProcessedURL = effectiveURL
        _lastProcessedTime = now
        _lastCapturedImage = image
        stateLock.unlock()

        writeClipboardPayload(image: image, text: "", fileURL: effectiveURL)

        ocrService.process(image) { [weak self, logStore] text in
            guard let self else { return }
            self.scanQueue.async {
                self.stateLock.lock()
                self._lastOCRText = text
                self._lastCapturedImage = image
                self.stateLock.unlock()
                self.writeClipboardPayload(image: image, text: text, fileURL: effectiveURL)
                self.processed.insert(key)
                self.processing.remove(key)
                Task { @MainActor in
                    logStore.addCapture(from: image, fileURL: effectiveURL, text: text)
                }

                self.scanQueue.asyncAfter(deadline: .now() + 65) { [weak self] in
                    guard let self else { return }
                    self.stateLock.lock()
                    let stillRecent = Date().timeIntervalSince(self._lastProcessedTime) < 60
                    if !stillRecent { self._lastCapturedImage = nil }
                    self.stateLock.unlock()
                }
            }
        }
    }

    private func persistToCaptures(data: Data, originalURL: URL) -> URL? {
        let parent = originalURL.deletingLastPathComponent().standardizedFileURL
        let destinationDir = capturesDirectory.standardizedFileURL

        if parent == destinationDir {
            return originalURL
        }

        let destination = uniqueDestinationURL(for: originalURL.lastPathComponent, in: destinationDir)

        do {
            try data.write(to: destination, options: .atomic)
            try? FileManager.default.removeItem(at: originalURL)
            return destination
        } catch {
            logger.error("Failed to persist screenshot to Captures: \(error.localizedDescription)")
            return nil
        }
    }

    private func writeClipboardPayload(image: NSImage, text: String, fileURL: URL?) {
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            let item = NSPasteboardItem()

            if let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
                if let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    item.setData(png, forType: .png)
                }
            }

            if let fileURL {
                item.setString(fileURL.absoluteString, forType: .fileURL)
            }

            if !text.isEmpty {
                item.setString(text, forType: .string)
            }

            pasteboard.writeObjects([item])
        }
    }

    private func uniqueDestinationURL(for fileName: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        let baseName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: fileName).pathExtension

        var attempt = 0
        var destination: URL

        repeat {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let candidateName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            destination = directory.appendingPathComponent(candidateName, isDirectory: false)
            attempt += 1
        } while fileManager.fileExists(atPath: destination.path)

        return destination
    }

    private func performCleanup() {
        let retentionSeconds = TimeInterval(captureRetentionDays * 86_400)
        let cutoff = Date().addingTimeInterval(-retentionSeconds)
        let fm = FileManager.default

        do {
            let files = try fm.contentsOfDirectory(
                at: capturesDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey]
            )
            var deleted = 0
            for file in files {
                if file.lastPathComponent.hasPrefix(".") { continue }
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey])
                if values?.isDirectory == true { continue }
                let ts = values?.contentModificationDate ?? values?.creationDate ?? Date()
                if ts < cutoff {
                    if (try? fm.removeItem(at: file)) != nil {
                        deleted += 1
                    }
                }
            }
            if deleted > 0 {
                logger.info("Auto-cleanup removed \(deleted) captures older than \(self.captureRetentionDays) days")
            }
        } catch {
            logger.error("Cleanup scan failed: \(error.localizedDescription)")
        }

        processed.prune(olderThan: retentionSeconds, maxCount: 500)
    }
}
