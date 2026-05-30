import SwiftUI
import AppKit

enum NotchHistoryEntry: Identifiable {
    case capture(CaptureItem)
    case shelf(ShelfItem)

    var id: String {
        switch self {
        case .capture(let c): return "c-\(c.id.uuidString)"
        case .shelf(let s): return "s-\(s.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .capture(let c): return c.timestamp
        case .shelf(let s): return s.dateAdded
        }
    }

    var image: NSImage? {
        switch self {
        case .capture(let c): return c.previewImage ?? c.fullImage()
        case .shelf(let s):
            switch s.type {
            case .image, .webImage: return s.image
            default: return nil
            }
        }
    }

    var title: String {
        switch self {
        case .capture(let c):
            let text = c.extractedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? c.fileName : text
        case .shelf(let s): return s.name
        }
    }

    var glyph: String {
        switch self {
        case .capture: return "photo"
        case .shelf(let s): return s.type.icon
        }
    }

    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var sizeText: String? {
        guard let bytes = byteCount, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var byteCount: Int? {
        switch self {
        case .capture(let c):
            if let n = c.imageData?.count, n > 0 { return n }
            if let url = c.sourceURL,
               let n = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { return n }
            return c.previewData?.count
        case .shelf(let s):
            if let url = s.url,
               let n = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { return n }
            return s.image?.tiffRepresentation?.count
        }
    }

    func makeDragProvider() -> NSItemProvider {
        switch self {
        case .capture(let c):
            if let url = c.sourceURL, url.isFileURL, let provider = NSItemProvider(contentsOf: url) { return provider }
            if let image = c.fullImage() { return NSItemProvider(object: image) }
            return NSItemProvider()
        case .shelf(let s):
            if let url = s.url, url.isFileURL, let provider = NSItemProvider(contentsOf: url) { return provider }
            if let image = s.image { return NSItemProvider(object: image) }
            return NSItemProvider()
        }
    }

    static func feed(captures: [CaptureItem], shelf: [ShelfItem], search: String) -> [NotchHistoryEntry] {
        var entries: [NotchHistoryEntry] = shelf.map { .shelf($0) } + captures.map { .capture($0) }
        entries.sort { $0.date > $1.date }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
    }

    private var searchableText: String {
        switch self {
        case .capture(let c): return [c.fileName, c.extractedText ?? ""].joined(separator: " ")
        case .shelf(let s): return s.name
        }
    }
}
