import Foundation

enum NotchFilter: Equatable {
    case all
    case images
    case blocks
    case tag(String)
}

enum NotchFeedItem: Identifiable {
    case capture(CaptureItem)
    case block(BlockEntity)

    var id: String {
        switch self {
        case .capture(let c): return "c-\(c.id.uuidString)"
        case .block(let b): return "b-\(b.id)"
        }
    }

    var date: Date {
        switch self {
        case .capture(let c): return c.timestamp
        case .block(let b): return b.lastEdited
        }
    }

    var searchText: String {
        switch self {
        case .capture(let c): return [c.fileName, c.extractedText ?? ""].joined(separator: " ")
        case .block(let b): return [b.displayTitle, b.markdown].joined(separator: " ")
        }
    }
}

extension String {
    var notchBlockPreview: String {
        var text = self
        if text.hasPrefix("---") {
            let parts = text.components(separatedBy: "\n---")
            if parts.count > 1 { text = parts.dropFirst().joined(separator: "\n---") }
        }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let joined = lines.joined(separator: " ")
        let cleaned = joined
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "> ", with: "")
        return String(cleaned.prefix(180))
    }
}
