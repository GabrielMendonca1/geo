import Foundation

enum FlushRejection: Equatable {
    case repetition(size: Int, count: Int)
    case tooFast(words: Int, seconds: Double)
    case tooLong(words: Int)

    var message: String {
        switch self {
        case .repetition(let size, let count):
            return "repetição degenerada (\(size)-grama \(count)×)"
        case .tooFast(let words, let seconds):
            return "\(words) palavras em \(String(format: "%.1f", seconds))s"
        case .tooLong(let words):
            return "\(words) palavras no flush"
        }
    }
}

enum FlushGuard {
    static func rejection(tail: String, windowSeconds: Double) -> FlushRejection? {
        let tokens = tokenize(tail)
        guard !tokens.isEmpty else { return nil }

        if tokens.count > Config.flushMaxTailWords {
            return .tooLong(words: tokens.count)
        }
        return implausibility(tokens, windowSeconds: windowSeconds)
    }

    static func stepRejection(tail: String, windowSeconds: Double) -> FlushRejection? {
        let tokens = tokenize(tail)
        guard !tokens.isEmpty else { return nil }
        return implausibility(tokens, windowSeconds: windowSeconds)
    }

    private static func tokenize(_ tail: String) -> [String] {
        tail
            .split(whereSeparator: \.isWhitespace)
            .map { Stabilizer.normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func implausibility(_ tokens: [String], windowSeconds: Double) -> FlushRejection? {
        let seconds = max(0, windowSeconds)
        let budget = Int(seconds * Config.flushMaxWordsPerSecond) + Config.flushWordSlack
        if tokens.count > budget {
            return .tooFast(words: tokens.count, seconds: seconds)
        }
        return repetition(tokens)
    }

    private static func repetition(_ tokens: [String]) -> FlushRejection? {
        var worst: FlushRejection?
        var worstCount = Config.flushMaxNgramRepeats
        var size = Config.flushMinNgram
        while size <= Config.flushMaxNgram {
            guard tokens.count >= size else { break }
            var seen: [String: Int] = [:]
            var index = 0
            while index + size <= tokens.count {
                let key = tokens[index..<(index + size)].joined(separator: " ")
                let count = (seen[key] ?? 0) + 1
                seen[key] = count
                if count > worstCount {
                    worstCount = count
                    worst = .repetition(size: size, count: count)
                }
                index += 1
            }
            size += 1
        }
        return worst
    }
}
