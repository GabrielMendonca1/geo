import AppKit
import ImageIO

final class ScreenshotClipboard {
    private var watcher: PathWatcher?
    private var folder = ""
    private var lastCopiedAt = Date.distantPast

    static func folder(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture")) -> String {
        let configured = defaults?.string(forKey: "location") ?? ""
        let path = (configured as NSString).expandingTildeInPath
        return path.isEmpty ? NSHomeDirectory() + "/Desktop" : path
    }

    static func isScreenshot(_ name: String) -> Bool {
        let lower = name.lowercased()
        let prefixes = ["screenshot", "screen shot", "captura de tela"]
        return !name.hasPrefix(".") && prefixes.contains(where: lower.hasPrefix)
            && (lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".heic"))
    }

    func start() {
        guard watcher == nil else { return }
        folder = Self.folder()
        lastCopiedAt = Date()
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
                      created > lastCopiedAt else { return nil }
                return (entry, created)
            }
            .max { $0.1 < $1.1 }
        guard let (file, created) = newest,
              let data = try? Data(contentsOf: file), !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return }
        lastCopiedAt = created
        let types: [String: String] = ["png": "public.png", "jpg": "public.jpeg", "heic": "public.heic"]
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(types[file.pathExtension.lowercased()] ?? "public.png"))
        item.setString(file.absoluteString, forType: .fileURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}
