import Foundation

struct SpokenWord: Equatable {
    let text: String
    let start: Double
    let end: Double

    init(text: String, start: Double, end: Double) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.start = start
        self.end = end
    }
}

struct Stabilizer {
    private(set) var committedText = ""
    private(set) var commitTime: Double = 0

    private var history: [[SpokenWord]] = []
    private var boundaries: [Double] = []
    private let agreementSteps: Int
    private let margin: Double
    private let overlapWords: Int

    init(agreementSteps: Int, margin: Double, overlapWords: Int) {
        self.agreementSteps = max(1, agreementSteps)
        self.margin = margin
        self.overlapWords = max(0, overlapWords)
    }

    var retainedBoundaryCount: Int { boundaries.count }

    func anchoredWindowStart(backoff: Double) -> Double {
        let target = max(commitTime - backoff, 0)
        guard target > 0 else { return 0 }
        let floorLimit = target - Config.seamSnapSlackSeconds
        guard let snapped = boundaries.last(where: { $0 <= target && $0 >= floorLimit }) else {
            return target
        }
        return snapped
    }

    mutating func step(words: [SpokenWord], windowStart: Double = 0, windowEnd: Double) -> String {
        let fresh = Stabilizer.trimmingLeadingFragment(
            words.filter { !$0.text.isEmpty },
            windowStart: windowStart,
            commitTime: commitTime
        )
        recordBoundaries(fresh)
        history.append(fresh)
        if history.count > agreementSteps {
            history.removeFirst(history.count - agreementSteps)
        }
        guard history.count >= agreementSteps else { return "" }

        var agreed = history[0]
        for candidate in history.dropFirst() {
            agreed = Stabilizer.commonPrefix(agreed, candidate)
            if agreed.isEmpty { break }
        }
        guard !agreed.isEmpty else { return "" }

        let cut = windowEnd - margin
        var committable: [SpokenWord] = []
        for word in agreed {
            guard word.end <= cut else { break }
            committable.append(word)
        }
        guard let last = committable.last else { return "" }

        let addition = committable.map(\.text).joined(separator: " ")
        let remainder = Stabilizer.strippingOverlap(
            committed: committedText,
            tail: addition,
            maxWords: overlapWords
        )
        let following = agreed.count > committable.count ? agreed[committable.count].start : last.end
        commitTime = max(commitTime, (last.end + max(following, last.end)) / 2)
        history.removeAll(keepingCapacity: true)
        return append(remainder)
    }

    mutating func forceCommit(
        words: [SpokenWord],
        windowStart: Double,
        cut: Double
    ) -> String {
        let fresh = Stabilizer.trimmingLeadingFragment(
            words.filter { !$0.text.isEmpty },
            windowStart: windowStart,
            commitTime: commitTime
        )
        recordBoundaries(fresh)
        var committable: [SpokenWord] = []
        for word in fresh {
            guard word.end <= cut else { break }
            committable.append(word)
        }
        guard let last = committable.last else { return "" }
        let addition = committable.map(\.text).joined(separator: " ")
        let remainder = Stabilizer.strippingOverlap(
            committed: committedText,
            tail: addition,
            maxWords: overlapWords
        )
        let following = fresh.count > committable.count ? fresh[committable.count].start : last.end
        commitTime = max(commitTime, (last.end + max(following, last.end)) / 2)
        history.removeAll(keepingCapacity: true)
        return append(remainder)
    }

    mutating func commitFinal(_ tail: String) -> String {
        let remainder = Stabilizer.strippingOverlap(
            committed: committedText,
            tail: tail,
            maxWords: overlapWords
        )
        return append(remainder)
    }

    static func trimmingLeadingFragment(
        _ words: [SpokenWord],
        windowStart: Double,
        commitTime: Double
    ) -> [SpokenWord] {
        guard windowStart > 0, let first = words.first else { return words }
        guard first.start <= windowStart + Config.seamOnsetToleranceSeconds else { return words }
        guard first.end <= commitTime else { return words }
        guard first.end - first.start <= Config.seamFragmentMaxSeconds else { return words }
        return Array(words.dropFirst())
    }

    private mutating func recordBoundaries(_ words: [SpokenWord]) {
        guard words.count >= 2 else { return }
        var fresh: [Double] = []
        for index in 0..<(words.count - 1) {
            let onset = words[index + 1].start
            if onset - words[index].end >= Config.seamSilenceGapSeconds {
                fresh.append((words[index].end + onset) / 2)
            }
            fresh.append(onset)
        }
        guard !fresh.isEmpty else { return }
        boundaries.append(contentsOf: fresh)
        boundaries.sort()
        let horizon = commitTime - Config.seamBoundaryRetentionSeconds
        boundaries = boundaries.filter { $0 >= horizon }
        var deduped: [Double] = []
        for value in boundaries where deduped.last.map({ abs(value - $0) > 1e-6 }) ?? true {
            deduped.append(value)
        }
        boundaries = deduped
        if boundaries.count > Config.seamMaxRetainedBoundaries {
            boundaries.removeFirst(boundaries.count - Config.seamMaxRetainedBoundaries)
        }
    }

    private mutating func append(_ remainder: String) -> String {
        let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let delta = committedText.isEmpty ? trimmed : " " + trimmed
        committedText += delta
        return delta
    }

    static func commonPrefix(_ lhs: [SpokenWord], _ rhs: [SpokenWord]) -> [SpokenWord] {
        var result: [SpokenWord] = []
        var index = 0
        while index < lhs.count, index < rhs.count {
            guard normalize(lhs[index].text) == normalize(rhs[index].text) else { break }
            result.append(rhs[index])
            index += 1
        }
        return result
    }

    static let maxLeadingFragments = 2

    static func strippingOverlap(committed: String, tail: String, maxWords: Int) -> String {
        let tailWords = tail.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tailWords.isEmpty, maxWords > 0 else { return tail }
        let committedWords = committed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !committedWords.isEmpty else { return tail }

        let limit = min(maxWords, min(tailWords.count, committedWords.count))
        var size = limit
        while size >= 1 {
            let suffix = committedWords.suffix(size).map(normalize)
            guard !suffix.contains(where: \.isEmpty) else {
                size -= 1
                continue
            }
            var skip = 0
            while skip <= maxLeadingFragments {
                guard skip == 0 || size >= 2 else { break }
                guard skip + size <= tailWords.count else { break }
                let slice = tailWords[skip..<(skip + size)].map(normalize)
                if slice == suffix {
                    return tailWords.dropFirst(skip + size).joined(separator: " ")
                }
                skip += 1
            }
            size -= 1
        }
        return tail
    }

    static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
