import AppKit

final class ScreenshotClipboard {
    private var watcher: PathWatcher?
    private var folder = ""
    private var startedAt = Date()
    private var lastCopied = ""

    static func folder(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture")) -> String {
        let configured = defaults?.string(forKey: "location") ?? ""
        let path = (configured as NSString).expandingTildeInPath
        return path.isEmpty ? NSHomeDirectory() + "/Desktop" : path
    }

    static func isScreenshot(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !name.hasPrefix(".") && lower.hasPrefix("screenshot")
            && (lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".heic"))
    }

    func start() {
        guard watcher == nil else { return }
        folder = Self.folder()
        startedAt = Date()
        let watcher = PathWatcher(
            paths: [folder],
            latency: 0.05,
            accepts: { Self.isScreenshot(($0 as NSString).lastPathComponent) },
            onChange: { [weak self] in self?.scan() }
        )
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    private func scan() {
        let url = URL(fileURLWithPath: folder)
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        let newest = entries
            .filter { Self.isScreenshot($0.lastPathComponent) }
            .compactMap { entry -> (URL, Date)? in
                guard let created = try? entry.resourceValues(forKeys: Set(keys)).creationDate,
                      created >= startedAt else { return nil }
                return (entry, created)
            }
            .max { $0.1 < $1.1 }
        guard let (file, _) = newest, file.path != lastCopied,
              let data = try? Data(contentsOf: file), !data.isEmpty else { return }
        lastCopied = file.path
        let item = NSPasteboardItem()
        let type: NSPasteboard.PasteboardType = file.pathExtension.lowercased() == "png" ? .png : .tiff
        if type == .png {
            item.setData(data, forType: .png)
        } else if let tiff = NSImage(data: data)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        item.setString(file.absoluteString, forType: .fileURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}
