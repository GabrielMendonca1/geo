import Foundation

enum TextChunker {
    static func sanitize(_ text: String) -> String {
        let flattened = text.map { $0.isNewline ? " " : $0 }
        var result = ""
        var lastWasSpace = false
        for character in flattened {
            let isSpace = character == " "
            if isSpace, lastWasSpace { continue }
            result.append(character)
            lastWasSpace = isSpace
        }
        return result
    }

    static func chunks(_ text: String, limit: Int) -> [String] {
        guard limit > 0, !text.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = String(character).utf16.count
            if currentUnits > 0, currentUnits + units > limit {
                result.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
