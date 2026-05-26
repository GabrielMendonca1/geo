import SwiftUI
import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "LogStore")

@MainActor
class LogStore: ObservableObject {
    static let shared = LogStore()
    private nonisolated static let maxHistoryItems = 200
    private nonisolated static let migrationVersion = 2
    private nonisolated static let migrationVersionDefaultsKey = "LogStore.captureHistoryMigrationVersion"
    
    @Published var captures: [CaptureItem] = []
    
    private struct MigrationSummary {
        let items: [CaptureItem]
        let strippedLegacyCount: Int
        let materializedCount: Int
        let retainedLegacyCount: Int
    }
    
    private let persistenceQueue = DispatchQueue(label: "com.geo.logstore.persistence", qos: .utility)
    private nonisolated(unsafe) let defaults = UserDefaults.standard
    private var pendingPersistWorkItem: DispatchWorkItem?
    private let persistDebounceInterval: TimeInterval = 0.35
    nonisolated let capturesDirectory: URL
    private nonisolated let storageURL: URL
    private var dayManager: DayManager?

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
        FileManager.default.homeDirectoryForCurrentUser
        
        let directory = baseURL.appendingPathComponent("Geo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        
        let capturesDirectory = directory.appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true, attributes: nil)
        self.capturesDirectory = capturesDirectory
        
        storageURL = directory.appendingPathComponent("capture-history.json")
        loadPersistedCaptures()
    }
    
    func configure(dayManager: DayManager) {
        self.dayManager = dayManager
    }

    func addCapture(from image: NSImage, fileURL: URL?, text: String) {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("LogStore", operation: "addCapture")
        defer { PerformanceTracker.shared.endStoreOperation("LogStore", operation: "addCapture", signpostID: spID, startTime: spStart) }
        let name = fileURL?.lastPathComponent ?? "Captura"
        DispatchQueue.global(qos: .userInitiated).async {
            let previewData = self.makePreviewData(from: image, maxDimension: 300)
            var resolvedSourceURL = fileURL
            var fallbackImageData: Data?
            
            if !self.isReachable(resolvedSourceURL) {
                resolvedSourceURL = self.materializeImageFromMemory(
                    image: image,
                    suggestedFileName: name
                )
            }
            
            if resolvedSourceURL == nil {
                fallbackImageData = self.pngData(from: image)
            }
            
            let item = CaptureItem(
                fileName: name,
                extractedText: text,
                sourceURL: resolvedSourceURL,
                previewData: previewData,
                imageData: fallbackImageData
            )

            DispatchQueue.main.async {
                self.appendCapture(item)
            }
        }
    }

    func addLog(_ message: String, text: String? = nil) {
        let item = CaptureItem(
            fileName: message,
            extractedText: text,
            sourceURL: nil,
            previewData: nil,
            imageData: nil
        )
        appendCapture(item)
    }

    func appendCapture(_ item: CaptureItem) {
        var storedItem = item
        if storedItem.dayId == nil {
            storedItem.dayId = Day.idFromDate(storedItem.timestamp)
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            captures.insert(storedItem, at: 0)
            enforceRetentionLimit()
        }
        schedulePersistCaptures()
        dayManager?.recordCaptureCreation(
            id: storedItem.id,
            date: storedItem.timestamp,
            dayId: storedItem.dayId
        )
    }
    
    func deleteCaptures(with ids: Set<UUID>) {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("LogStore", operation: "delete")
        defer { PerformanceTracker.shared.endStoreOperation("LogStore", operation: "delete", signpostID: spID, startTime: spStart) }
        guard !ids.isEmpty else { return }

        withAnimation(.easeInOut) {
            captures.removeAll { ids.contains($0.id) }
        }
        schedulePersistCaptures()
    }
    
    func capture(with id: UUID) -> CaptureItem? {
        captures.first(where: { $0.id == id })
    }

    func linkCaptureToDay(_ captureId: UUID, dayId: String) {
        guard let index = captures.firstIndex(where: { $0.id == captureId }) else { return }
        guard captures[index].dayId != dayId else { return }
        captures[index].dayId = dayId
        schedulePersistCaptures()
    }

    private func loadPersistedCaptures() {
        persistenceQueue.async {
            let data: Data
            do {
                data = try Data(contentsOf: self.storageURL)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return
            } catch {
                logger.error("Failed to read captures file: \(error.localizedDescription)")
                return
            }
            
            do {
                var decoded = try JSONDecoder().decode([CaptureItem].self, from: data)
                let initialCount = decoded.count
                let storedVersion = self.defaults.integer(forKey: Self.migrationVersionDefaultsKey)
                var migrationSummary: MigrationSummary?
                
                if storedVersion < Self.migrationVersion {
                    if decoded.contains(where: { $0.imageData != nil }) {
                        migrationSummary = self.migrateLegacyPayloadsIfNeeded(decoded, backupData: data)
                        if let summary = migrationSummary {
                            decoded = summary.items
                        }
                    }
                    self.defaults.set(Self.migrationVersion, forKey: Self.migrationVersionDefaultsKey)
                }
                
                let normalized = self.normalizedCaptures(decoded)
                if migrationSummary != nil || normalized.count != initialCount {
                    self.persistSnapshot(normalized)
                }
                
                DispatchQueue.main.async {
                    self.captures = normalized
                }
            } catch {
                logger.error("Load failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func schedulePersistCaptures() {
        let snapshot = captures
        pendingPersistWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistSnapshot(snapshot)
        }
        pendingPersistWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + persistDebounceInterval, execute: workItem)
    }
    
    private nonisolated func persistSnapshot(_ snapshot: [CaptureItem]) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Persist failed: \(error.localizedDescription)")
        }
    }
    
    private nonisolated func migrateLegacyPayloadsIfNeeded(_ captures: [CaptureItem], backupData: Data) -> MigrationSummary {
        let backupURL = captureHistoryBackupURL()
        do {
            try backupData.write(to: backupURL, options: .atomic)
            logger.info("Migration backup written path=\(backupURL.path)")
        } catch {
            logger.error("Migration backup failed: \(error.localizedDescription)")
        }
        
        var strippedLegacyCount = 0
        var materializedCount = 0
        var retainedLegacyCount = 0
        
        let compacted = captures.map { item -> CaptureItem in
            var sourceURL = item.sourceURL
            var imageData = item.imageData
            
            if isReachable(sourceURL), imageData != nil {
                imageData = nil
                strippedLegacyCount += 1
            } else if !isReachable(sourceURL), let legacyData = imageData {
                if let materializedURL = materializeImageData(
                    legacyData,
                    suggestedFileName: item.fileName,
                    preferredID: item.id
                ) {
                    sourceURL = materializedURL
                    imageData = nil
                    strippedLegacyCount += 1
                    materializedCount += 1
                } else {
                    retainedLegacyCount += 1
                }
            }
            
            return CaptureItem(
                id: item.id,
                timestamp: item.timestamp,
                fileName: item.fileName,
                extractedText: item.extractedText,
                sourceURL: sourceURL,
                previewData: item.previewData,
                imageData: imageData,
                dayId: item.dayId
            )
        }
        
        return MigrationSummary(
            items: normalizedCaptures(compacted),
            strippedLegacyCount: strippedLegacyCount,
            materializedCount: materializedCount,
            retainedLegacyCount: retainedLegacyCount
        )
    }
    
    private nonisolated func captureHistoryBackupURL() -> URL {
        let timestamp = DateFormatters.fileTimestamp.string(from: Date())
        let backupName = "capture-history.backup-\(timestamp).json"
        return storageURL.deletingLastPathComponent().appendingPathComponent(backupName)
    }
    
    private nonisolated func normalizedCaptures(_ items: [CaptureItem]) -> [CaptureItem] {
        Array(
            items
                .sorted(by: { $0.timestamp > $1.timestamp })
                .prefix(Self.maxHistoryItems)
        )
    }
    
    private func enforceRetentionLimit() {
        guard captures.count > Self.maxHistoryItems else { return }
        captures.removeSubrange(Self.maxHistoryItems..<captures.count)
    }


    private static func byteCountString(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
    
    private nonisolated func isReachable(_ url: URL?) -> Bool {
        guard let url else { return false }
        return (try? url.checkResourceIsReachable()) ?? false
    }
    
    private nonisolated func materializeImageFromMemory(image: NSImage, suggestedFileName: String) -> URL? {
        guard let data = pngData(from: image) else { return nil }
        return materializeImageData(data, suggestedFileName: suggestedFileName, preferredID: nil)
    }
    
    private nonisolated func materializeImageData(_ data: Data, suggestedFileName: String, preferredID: UUID?) -> URL? {
        let baseFileName = URL(fileURLWithPath: suggestedFileName).deletingPathExtension().lastPathComponent
        let sanitizedBase = sanitizedCaptureBaseName(baseFileName)
        let identifier = preferredID?.uuidString.prefix(8) ?? UUID().uuidString.prefix(8)
        let fileName = "\(sanitizedBase)-\(identifier).png"
        let destinationURL = uniqueDestinationURL(for: fileName, in: capturesDirectory)
        
        do {
            try data.write(to: destinationURL, options: .atomic)
            return destinationURL
        } catch {
            logger.error("Failed to materialize legacy image fileName=\(fileName) error=\(error.localizedDescription)")
            return nil
        }
    }
    
    private nonisolated func uniqueDestinationURL(for fileName: String, in directory: URL) -> URL {
        let baseName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: fileName).pathExtension
        
        var attempt = 0
        var destinationURL: URL
        repeat {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let candidateName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            destinationURL = directory.appendingPathComponent(candidateName, isDirectory: false)
            attempt += 1
        } while FileManager.default.fileExists(atPath: destinationURL.path)
        
        return destinationURL
    }
    
    private nonisolated func sanitizedCaptureBaseName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "capture" }
        
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalarView = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(scalarView)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "capture" : sanitized
    }
    
    private nonisolated func makePreviewData(from image: NSImage, maxDimension: CGFloat) -> Data? {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)
        let aspect = originalWidth / originalHeight

        let targetWidth: Int
        let targetHeight: Int
        if aspect > 1 {
            targetWidth = Int(maxDimension)
            targetHeight = max(1, Int(maxDimension / aspect))
        } else {
            targetWidth = max(1, Int(maxDimension * aspect))
            targetHeight = Int(maxDimension)
        }

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let scaledImage = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaledImage)
        return rep.representation(using: .png, properties: [:])
    }
    
    private nonisolated func pngData(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}
