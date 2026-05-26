import Foundation

struct InlineCheckboxMetadata: Equatable {
    let title: String
    let priority: TaskPriority
    let startTime: Date?
    let tagNames: [String]
}

enum InlineCheckboxParser {
    static func parse(_ rawText: String, now: Date = Date(), calendar: Calendar = .current) -> InlineCheckboxMetadata {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return InlineCheckboxMetadata(title: "", priority: .unset, startTime: nil, tagNames: [])
        }

        var ranges: [Range<String.Index>] = []

        let startTime = extractDate(from: trimmed, ranges: &ranges, now: now, calendar: calendar)
        let priority = extractPriority(from: trimmed, ranges: &ranges)
        let tagNames = extractTags(from: trimmed, ranges: &ranges)
        let title = stripRanges(from: trimmed, ranges: ranges)

        return InlineCheckboxMetadata(
            title: title,
            priority: priority,
            startTime: startTime,
            tagNames: tagNames
        )
    }
}

private extension InlineCheckboxParser {
    static func extractPriority(from input: String, ranges: inout [Range<String.Index>]) -> TaskPriority {
        let patterns: [(String, TaskPriority)] = [
            ("(?<=^|\\s)!!!(?=$|\\s)", .urgent),
            ("(?<=^|\\s)!!urgent\\b", .urgent),
            ("(?<=^|\\s)!urgent\\b", .urgent),
            ("(?<=^|\\s)!!high\\b", .high),
            ("(?<=^|\\s)!high\\b", .high),
            ("(?<=^|\\s)!!(?=$|\\s)", .high),
            ("(?<=^|\\s)!medium\\b", .medium),
            ("(?<=^|\\s)!low\\b", .low),
            ("(?<=^|\\s)!(?=$|\\s)", .medium),
        ]

        for (pattern, priority) in patterns {
            if let match = firstMatch(in: input, pattern: pattern),
               let range = range(of: match, in: input),
               !ranges.contains(where: { $0.overlaps(range) }) {
                ranges.append(range)
                return priority
            }
        }
        return .unset
    }

    static func extractTags(from input: String, ranges: inout [Range<String.Index>]) -> [String] {
        let pattern = "(?<=^|\\s)#([A-Za-z0-9_-]+)"
        var tags: [String] = []
        for match in allMatches(in: input, pattern: pattern) {
            guard let full = range(of: match, in: input),
                  let nameRange = range(of: match, in: input, group: 1),
                  !ranges.contains(where: { $0.overlaps(full) }) else { continue }
            let name = String(input[nameRange])
            if !tags.contains(name) {
                tags.append(name)
            }
            ranges.append(full)
        }
        return tags
    }

    static func extractDate(
        from input: String,
        ranges: inout [Range<String.Index>],
        now: Date,
        calendar: Calendar
    ) -> Date? {
        if let m = firstMatch(in: input, pattern: "(?<=^|\\s)@(today|hoje)\\b"),
           let r = range(of: m, in: input) {
            ranges.append(r)
            return now
        }

        if let m = firstMatch(in: input, pattern: "(?<=^|\\s)@(tomorrow|amanha|amanhã)\\b"),
           let r = range(of: m, in: input) {
            ranges.append(r)
            return calendar.date(byAdding: .day, value: 1, to: now)
        }

        if let m = firstMatch(in: input, pattern: "(?<=^|\\s)@next\\s+week\\b"),
           let r = range(of: m, in: input) {
            ranges.append(r)
            return calendar.date(byAdding: .day, value: 7, to: now)
        }

        let nextWeekdayPattern = "(?<=^|\\s)@next\\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\\b"
        if let m = firstMatch(in: input, pattern: nextWeekdayPattern),
           let r = range(of: m, in: input),
           let weekdayRange = range(of: m, in: input, group: 1) {
            let name = String(input[weekdayRange]).lowercased()
            if let weekday = weekdayNumber(for: name) {
                ranges.append(r)
                return nextWeekday(weekday, after: now, calendar: calendar, forceNextWeek: true)
            }
        }

        let isoPattern = "(?<=^|\\s)@(\\d{4})-(\\d{2})-(\\d{2})\\b"
        if let m = firstMatch(in: input, pattern: isoPattern),
           let full = range(of: m, in: input),
           let yR = range(of: m, in: input, group: 1),
           let mR = range(of: m, in: input, group: 2),
           let dR = range(of: m, in: input, group: 3),
           let year = Int(input[yR]),
           let month = Int(input[mR]),
           let day = Int(input[dR]) {
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            comps.hour = 0
            comps.minute = 0
            if let date = calendar.date(from: comps) {
                ranges.append(full)
                return date
            }
        }

        let weekdayPattern = "(?<=^|\\s)@(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\\b"
        if let m = firstMatch(in: input, pattern: weekdayPattern),
           let r = range(of: m, in: input),
           let weekdayRange = range(of: m, in: input, group: 1) {
            let name = String(input[weekdayRange]).lowercased()
            if let weekday = weekdayNumber(for: name) {
                ranges.append(r)
                return nextWeekday(weekday, after: now, calendar: calendar, forceNextWeek: false)
            }
        }

        return nil
    }

    static func weekdayNumber(for token: String) -> Int? {
        switch token {
        case "sunday", "sun": return 1
        case "monday", "mon": return 2
        case "tuesday", "tue", "tues": return 3
        case "wednesday", "wed": return 4
        case "thursday", "thu", "thur", "thurs": return 5
        case "friday", "fri": return 6
        case "saturday", "sat": return 7
        default: return nil
        }
    }

    static func nextWeekday(_ weekday: Int, after date: Date, calendar: Calendar, forceNextWeek: Bool) -> Date {
        let current = calendar.component(.weekday, from: date)
        var diff = weekday - current
        if diff <= 0 || forceNextWeek {
            diff += 7
        }
        return calendar.date(byAdding: .day, value: diff, to: calendar.startOfDay(for: date)) ?? date
    }

    static func stripRanges(from input: String, ranges: [Range<String.Index>]) -> String {
        guard !ranges.isEmpty else {
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sorted = ranges.sorted(by: { $0.lowerBound < $1.lowerBound })
        var merged: [Range<String.Index>] = []
        for r in sorted {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        var result = ""
        var cursor = input.startIndex
        for r in merged {
            if cursor < r.lowerBound {
                result += input[cursor..<r.lowerBound]
            }
            result += " "
            cursor = r.upperBound
        }
        if cursor < input.endIndex {
            result += input[cursor..<input.endIndex]
        }
        let collapsed = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstMatch(in text: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: nsRange)
    }

    static func allMatches(in text: String, pattern: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange)
    }

    static func range(of match: NSTextCheckingResult, in text: String, group: Int = 0) -> Range<String.Index>? {
        let r = match.range(at: group)
        guard r.location != NSNotFound else { return nil }
        return Range(r, in: text)
    }
}
