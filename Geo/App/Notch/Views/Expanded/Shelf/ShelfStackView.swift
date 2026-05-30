import Foundation

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
