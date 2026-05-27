import Foundation

struct ParsedQuickAdd: Equatable {
    let title: String
    let body: TaskBody
    let confidence: Confidence

    enum Confidence: Equatable {
        case high
        case medium
        case low
    }

    var kind: TaskKind { body.kind }
}

enum QuickAddParser {
    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedQuickAdd {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedQuickAdd(title: "", body: .task(due: endOfDay(for: now, calendar: calendar), estimatedMinutes: nil), confidence: .low)
        }

        var ranges: [Range<String.Index>] = []

        let duration = extractDuration(from: trimmed, ranges: &ranges)

        if let recurrence = extractRecurrence(from: trimmed, ranges: &ranges, now: now, calendar: calendar) {
            let title = stripRanges(from: trimmed, ranges: ranges)
            return ParsedQuickAdd(
                title: title,
                body: .habit(rule: recurrence.rule, timeOfDay: recurrence.timeOfDay, occurrences: []),
                confidence: recurrence.confidence
            )
        }

        if let target = extractTargetClause(from: trimmed, ranges: &ranges, now: now, calendar: calendar) {
            let title = stripRanges(from: trimmed, ranges: ranges)
            let dayDelta = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target.date)).day ?? 0
            let isMilestoneVerb = containsMilestoneVerb(title)
            let isMilestone = dayDelta > 7 || (isMilestoneVerb && dayDelta >= 7)
            let body: TaskBody = isMilestone
                ? .milestone(target: calendar.startOfDay(for: target.date))
                : .task(due: endOfDay(for: target.date, calendar: calendar), estimatedMinutes: nil)
            return ParsedQuickAdd(title: title, body: body, confidence: .high)
        }

        if let timeMatch = extractAbsoluteTime(from: trimmed, ranges: &ranges, now: now, calendar: calendar) {
            let title = stripRanges(from: trimmed, ranges: ranges)
            let resolvedDuration = duration ?? 3600
            let end = timeMatch.date.addingTimeInterval(resolvedDuration)
            return ParsedQuickAdd(
                title: title,
                body: .event(start: timeMatch.date, end: end),
                confidence: .high
            )
        }

        if let dateOnly = extractStandaloneDate(from: trimmed, ranges: &ranges, now: now, calendar: calendar) {
            let title = stripRanges(from: trimmed, ranges: ranges)
            let dayDelta = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: dateOnly)).day ?? 0
            let body: TaskBody = dayDelta > 7
                ? .milestone(target: calendar.startOfDay(for: dateOnly))
                : .task(due: endOfDay(for: dateOnly, calendar: calendar), estimatedMinutes: nil)
            return ParsedQuickAdd(title: title, body: body, confidence: .medium)
        }

        let title = stripRanges(from: trimmed, ranges: ranges)
        return ParsedQuickAdd(
            title: title.isEmpty ? trimmed : title,
            body: .task(due: endOfDay(for: now, calendar: calendar), estimatedMinutes: nil),
            confidence: .low
        )
    }
}

private extension QuickAddParser {
    static let milestoneVerbs: Set<String> = ["ship", "launch", "release", "finish", "hit", "deliver", "complete"]

    static func containsMilestoneVerb(_ text: String) -> Bool {
        for verb in milestoneVerbs {
            if firstMatch(in: text, pattern: "\\b\(verb)\\b") != nil {
                return true
            }
        }
        return false
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
        return collapsed.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;-")))
    }

    static func endOfDay(for date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date
    }
}

private struct RecurrenceMatch {
    let rule: RecurrenceRule
    let timeOfDay: Date
    let confidence: ParsedQuickAdd.Confidence
}

private struct DateMatch {
    let date: Date
    let range: Range<String.Index>
}

private struct TimeMatch {
    let date: Date
    let range: Range<String.Index>
}

private extension QuickAddParser {
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

private extension QuickAddParser {
    static func extractRecurrence(
        from input: String,
        ranges: inout [Range<String.Index>],
        now: Date,
        calendar: Calendar
    ) -> RecurrenceMatch? {
        if let m = firstMatch(in: input, pattern: "\\btwice\\s+daily\\b"),
           let r = range(of: m, in: input) {
            ranges.append(r)
            let timeOfDay = currentHourTime(now: now, calendar: calendar)
            return RecurrenceMatch(rule: .custom(every: 2, frequency: .daily), timeOfDay: timeOfDay, confidence: .high)
        }

        if let m = firstMatch(in: input, pattern: "\\b(on\\s+the\\s+)?\\d{1,2}(st|nd|rd|th)?\\s+of\\s+(every|each)\\s+month\\b"),
           let r = range(of: m, in: input) {
            ranges.append(r)
            let timeOfDay = morningTime(hour: 9, now: now, calendar: calendar)
            return RecurrenceMatch(rule: .monthly, timeOfDay: timeOfDay, confidence: .high)
        }

        if let m = firstMatch(in: input, pattern: "\\b(every|each)\\s+month\\b"),
           let r = range(of: m, in: input) {
            ranges.append(r)
            let timeOfDay = morningTime(hour: 9, now: now, calendar: calendar)
            return RecurrenceMatch(rule: .monthly, timeOfDay: timeOfDay, confidence: .high)
        }

        if let m = firstMatch(in: input, pattern: "\\b(every|each)\\s+year\\b"),
           let r = range(of: m, in: input) {
            ranges.append(r)
            let timeOfDay = morningTime(hour: 9, now: now, calendar: calendar)
            return RecurrenceMatch(rule: .yearly, timeOfDay: timeOfDay, confidence: .high)
        }

        if let m = firstMatch(in: input, pattern: "\\bevery\\s+weekday\\b"),
           let r = range(of: m, in: input) {
            ranges.append(r)
            var timeOfDay = currentHourTime(now: now, calendar: calendar)
            if let timeMatch = extractAbsoluteTime(from: input, ranges: &ranges, now: now, calendar: calendar, restrictToTime: true) {
                timeOfDay = timeMatch.date
            }
            return RecurrenceMatch(rule: .weekdays, timeOfDay: timeOfDay, confidence: .high)
        }

        if let m = firstMatch(in: input, pattern: "\\b(biweekly|bi-weekly|every\\s+two\\s+weeks|every\\s+other\\s+week)\\b"),
           let r = range(of: m, in: input) {
            ranges.append(r)
            let timeOfDay = currentHourTime(now: now, calendar: calendar)
            return RecurrenceMatch(rule: .biweekly, timeOfDay: timeOfDay, confidence: .high)
        }

        let weekdayPattern = "\\b(every|each)\\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\\b"
        if let m = firstMatch(in: input, pattern: weekdayPattern),
           let r = range(of: m, in: input) {
            let matched = String(input[r]).lowercased()
            let weekdayInt = parseWeekdayName(matched)
            ranges.append(r)

            var timeOfDay = currentHourTime(now: now, calendar: calendar)
            if let timeMatch = extractAbsoluteTime(from: input, ranges: &ranges, now: now, calendar: calendar, restrictToTime: true) {
                timeOfDay = timeMatch.date
            }

            let rule: RecurrenceRule = weekdayInt.map { RecurrenceRule.weekly(on: [$0]) } ?? .weekly
            return RecurrenceMatch(rule: rule, timeOfDay: timeOfDay, confidence: .high)
        }

        let dailyPattern = "\\b(every\\s+day|each\\s+day|daily|every\\s+morning|each\\s+morning|every\\s+evening|each\\s+evening|every\\s+night|each\\s+night|every\\s+afternoon|each\\s+afternoon)\\b"
        if let m = firstMatch(in: input, pattern: dailyPattern),
           let r = range(of: m, in: input) {
            let matched = String(input[r]).lowercased()
            ranges.append(r)
            var timeOfDay: Date
            if matched.contains("morning") {
                timeOfDay = morningTime(hour: 7, now: now, calendar: calendar)
            } else if matched.contains("evening") || matched.contains("night") {
                timeOfDay = morningTime(hour: 18, now: now, calendar: calendar)
            } else if matched.contains("afternoon") {
                timeOfDay = morningTime(hour: 14, now: now, calendar: calendar)
            } else {
                timeOfDay = currentHourTime(now: now, calendar: calendar)
            }
            if let timeMatch = extractAbsoluteTime(from: input, ranges: &ranges, now: now, calendar: calendar, restrictToTime: true) {
                timeOfDay = timeMatch.date
            }
            return RecurrenceMatch(rule: .daily, timeOfDay: timeOfDay, confidence: .high)
        }

        if let m = firstMatch(in: input, pattern: "\\b(weekly|every\\s+week|each\\s+week)\\b"),
           let r = range(of: m, in: input) {
            ranges.append(r)
            var timeOfDay = currentHourTime(now: now, calendar: calendar)
            let weekdayPat = "\\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\\b"
            var weekdayValue: Int?
            if let wm = firstMatch(in: input, pattern: weekdayPat),
               let wr = range(of: wm, in: input),
               !ranges.contains(where: { $0.overlaps(wr) }) {
                weekdayValue = parseWeekdayName(String(input[wr]).lowercased())
                ranges.append(wr)
            }
            if let timeMatch = extractAbsoluteTime(from: input, ranges: &ranges, now: now, calendar: calendar, restrictToTime: true) {
                timeOfDay = timeMatch.date
            }
            let rule: RecurrenceRule = weekdayValue.map { RecurrenceRule.weekly(on: [$0]) } ?? .weekly
            return RecurrenceMatch(rule: rule, timeOfDay: timeOfDay, confidence: .high)
        }

        return nil
    }

    static func currentHourTime(now: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        return calendar.date(bySettingHour: comps.hour ?? 9, minute: 0, second: 0, of: now) ?? now
    }

    static func morningTime(hour: Int, now: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
    }

    static func parseWeekdayName(_ token: String) -> Int? {
        let normalized = token.lowercased()
        if normalized.contains("sunday") || hasStandaloneToken(normalized, "sun") { return 1 }
        if normalized.contains("monday") || hasStandaloneToken(normalized, "mon") { return 2 }
        if normalized.contains("tuesday") || hasStandaloneToken(normalized, "tues") || hasStandaloneToken(normalized, "tue") { return 3 }
        if normalized.contains("wednesday") || hasStandaloneToken(normalized, "wed") { return 4 }
        if normalized.contains("thursday") || hasStandaloneToken(normalized, "thurs") || hasStandaloneToken(normalized, "thur") || hasStandaloneToken(normalized, "thu") { return 5 }
        if normalized.contains("friday") || hasStandaloneToken(normalized, "fri") { return 6 }
        if normalized.contains("saturday") || hasStandaloneToken(normalized, "sat") { return 7 }
        return nil
    }

    static func hasStandaloneToken(_ text: String, _ token: String) -> Bool {
        firstMatch(in: text, pattern: "\\b\(token)\\b") != nil
    }
}

private extension QuickAddParser {
    static func extractDuration(from input: String, ranges: inout [Range<String.Index>]) -> TimeInterval? {
        let pattern = "\\bfor\\s+(\\d+(?:\\.\\d+)?)\\s*(hours?|hrs?|h|minutes?|mins?|m)\\b"
        guard let match = firstMatch(in: input, pattern: pattern),
              let full = range(of: match, in: input),
              let numRange = range(of: match, in: input, group: 1),
              let unitRange = range(of: match, in: input, group: 2) else { return nil }
        let numStr = String(input[numRange])
        let unit = String(input[unitRange]).lowercased()
        guard let value = Double(numStr) else { return nil }
        ranges.append(full)
        return unit.hasPrefix("h") ? value * 3600 : value * 60
    }

    static func extractAbsoluteTime(
        from input: String,
        ranges: inout [Range<String.Index>],
        now: Date,
        calendar: Calendar,
        restrictToTime: Bool = false
    ) -> TimeMatch? {
        let timeWithMeridiem = "(?:\\b(?:at|@)\\s+)?(?<![0-9:])(\\d{1,2})(?::(\\d{2}))?\\s*([ap]\\.?m\\.?)\\b"
        for match in allMatches(in: input, pattern: timeWithMeridiem) {
            guard let full = range(of: match, in: input),
                  !ranges.contains(where: { $0.overlaps(full) }) else { continue }
            guard let hourRange = range(of: match, in: input, group: 1) else { continue }
            let hourStr = String(input[hourRange])
            let minuteStr = range(of: match, in: input, group: 2).map { String(input[$0]) }
            let meridiemStr = range(of: match, in: input, group: 3).map { String(input[$0]).lowercased() } ?? ""
            guard var hour = Int(hourStr), hour >= 1, hour <= 12 else { continue }
            let minute = minuteStr.flatMap { Int($0) } ?? 0
            if meridiemStr.hasPrefix("p") && hour < 12 { hour += 12 }
            if meridiemStr.hasPrefix("a") && hour == 12 { hour = 0 }
            let base = extractWeekdayAnchor(from: input, ranges: &ranges, now: now, calendar: calendar) ?? now
            let date = anchorTime(hour: hour, minute: minute, base: base, now: now, calendar: calendar)
            ranges.append(full)
            return TimeMatch(date: date, range: full)
        }

        let twentyFourPattern = "(?:\\b(?:at|@)\\s+)?\\b(\\d{1,2}):(\\d{2})\\b"
        for match in allMatches(in: input, pattern: twentyFourPattern) {
            guard let full = range(of: match, in: input),
                  !ranges.contains(where: { $0.overlaps(full) }) else { continue }
            guard let hourRange = range(of: match, in: input, group: 1),
                  let minuteRange = range(of: match, in: input, group: 2),
                  let hour = Int(input[hourRange]),
                  let minute = Int(input[minuteRange]) else { continue }
            guard hour >= 0, hour <= 23, minute >= 0, minute <= 59 else { continue }
            let base = extractWeekdayAnchor(from: input, ranges: &ranges, now: now, calendar: calendar) ?? now
            let date = anchorTime(hour: hour, minute: minute, base: base, now: now, calendar: calendar)
            ranges.append(full)
            return TimeMatch(date: date, range: full)
        }

        if !restrictToTime {
            let atHourPattern = "\\bat\\s+(\\d{1,2})\\b(?!\\s*[:./-]\\s*\\d)"
            if let match = firstMatch(in: input, pattern: atHourPattern),
               let full = range(of: match, in: input),
               !ranges.contains(where: { $0.overlaps(full) }),
               let hourRange = range(of: match, in: input, group: 1),
               let hour = Int(input[hourRange]),
               hour >= 0, hour <= 23 {
                let base = extractWeekdayAnchor(from: input, ranges: &ranges, now: now, calendar: calendar) ?? now
                let date = anchorTime(hour: hour, minute: 0, base: base, now: now, calendar: calendar)
                ranges.append(full)
                return TimeMatch(date: date, range: full)
            }
        }

        return nil
    }

    static func anchorTime(hour: Int, minute: Int, base: Date, now: Date, calendar: Calendar) -> Date {
        var result = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        if calendar.isDate(base, inSameDayAs: now), result < now {
            result = calendar.date(byAdding: .day, value: 1, to: result) ?? result
        }
        return result
    }

    static func extractWeekdayAnchor(
        from input: String,
        ranges: inout [Range<String.Index>],
        now: Date,
        calendar: Calendar
    ) -> Date? {
        if let m = firstMatch(in: input, pattern: "\\btomorrow\\b"),
           let r = range(of: m, in: input),
           !ranges.contains(where: { $0.overlaps(r) }) {
            ranges.append(r)
            return calendar.date(byAdding: .day, value: 1, to: now)
        }
        if let m = firstMatch(in: input, pattern: "\\btoday\\b"),
           let r = range(of: m, in: input),
           !ranges.contains(where: { $0.overlaps(r) }) {
            ranges.append(r)
            return now
        }

        let nextWeekdayPattern = "\\bnext\\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b"
        if let m = firstMatch(in: input, pattern: nextWeekdayPattern),
           let r = range(of: m, in: input) {
            let matched = String(input[r]).lowercased()
            if let weekday = parseWeekdayName(matched) {
                ranges.append(r)
                return nextWeekday(weekday, after: now, calendar: calendar, forceNextWeek: true)
            }
        }

        if let m = firstMatch(in: input, pattern: "\\bnext\\s+week\\b"),
           let r = range(of: m, in: input) {
            ranges.append(r)
            return calendar.date(byAdding: .day, value: 7, to: now)
        }

        let weekdayPattern = "\\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b"
        if let m = firstMatch(in: input, pattern: weekdayPattern),
           let r = range(of: m, in: input),
           !ranges.contains(where: { $0.overlaps(r) }) {
            let matched = String(input[r]).lowercased()
            if let weekday = parseWeekdayName(matched) {
                ranges.append(r)
                return nextWeekday(weekday, after: now, calendar: calendar, forceNextWeek: false)
            }
        }

        return nil
    }

    static func nextWeekday(_ weekday: Int, after date: Date, calendar: Calendar, forceNextWeek: Bool) -> Date {
        let current = calendar.component(.weekday, from: date)
        var diff = weekday - current
        if diff <= 0 || forceNextWeek {
            diff += 7
        }
        return calendar.date(byAdding: .day, value: diff, to: date) ?? date
    }
}

private extension QuickAddParser {
    static func extractTargetClause(
        from input: String,
        ranges: inout [Range<String.Index>],
        now: Date,
        calendar: Calendar
    ) -> DateMatch? {
        let prefixes = ["by", "before", "due", "until"]
        for prefix in prefixes {
            let pattern = "\\b\(prefix)\\s+"
            guard let prefixMatch = firstMatch(in: input, pattern: pattern),
                  let prefixRange = range(of: prefixMatch, in: input) else { continue }
            let remainder = String(input[prefixRange.upperBound...])
            if let dateMatch = parseDate(in: remainder, now: now, calendar: calendar) {
                let dateEndOffset = remainder.distance(from: remainder.startIndex, to: dateMatch.range.upperBound)
                let prefixEndOffset = input.distance(from: input.startIndex, to: prefixRange.upperBound)
                let combinedEnd = input.index(input.startIndex, offsetBy: prefixEndOffset + dateEndOffset)
                let combined = prefixRange.lowerBound..<combinedEnd
                ranges.append(combined)
                return DateMatch(date: dateMatch.date, range: combined)
            }
        }
        return nil
    }

    static func extractStandaloneDate(
        from input: String,
        ranges: inout [Range<String.Index>],
        now: Date,
        calendar: Calendar
    ) -> Date? {
        if let m = firstMatch(in: input, pattern: "\\btomorrow\\b"),
           let r = range(of: m, in: input),
           !ranges.contains(where: { $0.overlaps(r) }) {
            ranges.append(r)
            return calendar.date(byAdding: .day, value: 1, to: now)
        }
        if let m = firstMatch(in: input, pattern: "\\btoday\\b"),
           let r = range(of: m, in: input),
           !ranges.contains(where: { $0.overlaps(r) }) {
            ranges.append(r)
            return now
        }
        if let dm = parseDate(in: input, now: now, calendar: calendar),
           !ranges.contains(where: { $0.overlaps(dm.range) }) {
            ranges.append(dm.range)
            return dm.date
        }
        return nil
    }

    struct LocalDateMatch {
        let date: Date
        let range: Range<String.Index>
    }

    static func parseDate(in text: String, now: Date, calendar: Calendar) -> LocalDateMatch? {
        if let m = firstMatch(in: text, pattern: "\\btomorrow\\b"),
           let r = range(of: m, in: text),
           let date = calendar.date(byAdding: .day, value: 1, to: now) {
            return LocalDateMatch(date: date, range: r)
        }
        if let m = firstMatch(in: text, pattern: "\\btoday\\b"),
           let r = range(of: m, in: text) {
            return LocalDateMatch(date: now, range: r)
        }

        let inPattern = "\\bin\\s+(\\d+)\\s+(day|days|week|weeks|month|months)\\b"
        if let match = firstMatch(in: text, pattern: inPattern),
           let full = range(of: match, in: text),
           let nRange = range(of: match, in: text, group: 1),
           let unitRange = range(of: match, in: text, group: 2),
           let n = Int(text[nRange]) {
            let unit = String(text[unitRange]).lowercased()
            let component: Calendar.Component
            if unit.hasPrefix("week") { component = .weekOfYear }
            else if unit.hasPrefix("month") { component = .month }
            else { component = .day }
            if let date = calendar.date(byAdding: component, value: n, to: now) {
                return LocalDateMatch(date: date, range: full)
            }
        }

        if let m = firstMatch(in: text, pattern: "\\bnext\\s+week\\b"),
           let r = range(of: m, in: text),
           let date = calendar.date(byAdding: .day, value: 7, to: now) {
            return LocalDateMatch(date: date, range: r)
        }

        let nextWeekdayPattern = "\\bnext\\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b"
        if let m = firstMatch(in: text, pattern: nextWeekdayPattern),
           let r = range(of: m, in: text) {
            let matched = String(text[r]).lowercased()
            if let weekday = parseWeekdayName(matched) {
                return LocalDateMatch(date: nextWeekday(weekday, after: now, calendar: calendar, forceNextWeek: true), range: r)
            }
        }

        let weekdayPattern = "\\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b"
        if let m = firstMatch(in: text, pattern: weekdayPattern),
           let r = range(of: m, in: text) {
            let matched = String(text[r]).lowercased()
            if let weekday = parseWeekdayName(matched) {
                return LocalDateMatch(date: nextWeekday(weekday, after: now, calendar: calendar, forceNextWeek: false), range: r)
            }
        }

        if let m = parseMonthDayLong(in: text, now: now, calendar: calendar) {
            return m
        }

        if let m = parseNumericDate(in: text, now: now, calendar: calendar) {
            return m
        }

        return nil
    }

    static let monthMap: [String: Int] = [
        "january": 1, "jan": 1,
        "february": 2, "feb": 2,
        "march": 3, "mar": 3,
        "april": 4, "apr": 4,
        "may": 5,
        "june": 6, "jun": 6,
        "july": 7, "jul": 7,
        "august": 8, "aug": 8,
        "september": 9, "sept": 9, "sep": 9,
        "october": 10, "oct": 10,
        "november": 11, "nov": 11,
        "december": 12, "dec": 12
    ]

    static func parseMonthDayLong(in text: String, now: Date, calendar: Calendar) -> LocalDateMatch? {
        let monthAlt = monthMap.keys.sorted { $0.count > $1.count }.joined(separator: "|")

        let monthFirst = "\\b(\(monthAlt))\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b"
        if let match = firstMatch(in: text, pattern: monthFirst),
           let full = range(of: match, in: text),
           let monthR = range(of: match, in: text, group: 1),
           let dayR = range(of: match, in: text, group: 2) {
            let monthName = String(text[monthR]).lowercased()
            if let month = monthMap[monthName], let day = Int(text[dayR]),
               let date = makeYearAwareDate(month: month, day: day, now: now, calendar: calendar) {
                return LocalDateMatch(date: date, range: full)
            }
        }

        let dayFirst = "\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?(\(monthAlt))\\b"
        if let match = firstMatch(in: text, pattern: dayFirst),
           let full = range(of: match, in: text),
           let dayR = range(of: match, in: text, group: 1),
           let monthR = range(of: match, in: text, group: 2) {
            let monthName = String(text[monthR]).lowercased()
            if let month = monthMap[monthName], let day = Int(text[dayR]),
               let date = makeYearAwareDate(month: month, day: day, now: now, calendar: calendar) {
                return LocalDateMatch(date: date, range: full)
            }
        }
        return nil
    }

    static func parseNumericDate(in text: String, now: Date, calendar: Calendar) -> LocalDateMatch? {
        let pattern = "\\b(\\d{1,2})/(\\d{1,2})(?:/(\\d{2,4}))?\\b"
        guard let match = firstMatch(in: text, pattern: pattern),
              let full = range(of: match, in: text),
              let aR = range(of: match, in: text, group: 1),
              let bR = range(of: match, in: text, group: 2),
              let a = Int(text[aR]), let b = Int(text[bR]) else { return nil }

        let yearStr: Int? = {
            guard let yR = range(of: match, in: text, group: 3),
                  let y = Int(text[yR]) else { return nil }
            return y < 100 ? 2000 + y : y
        }()

        let (month, day) = disambiguateNumericDate(a: a, b: b, calendar: calendar)
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }

        if let year = yearStr {
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            comps.hour = 0
            comps.minute = 0
            if let date = calendar.date(from: comps) {
                return LocalDateMatch(date: date, range: full)
            }
            return nil
        }

        if let date = makeYearAwareDate(month: month, day: day, now: now, calendar: calendar) {
            return LocalDateMatch(date: date, range: full)
        }
        return nil
    }

    static func disambiguateNumericDate(a: Int, b: Int, calendar: Calendar) -> (month: Int, day: Int) {
        let usesUSFormat = (calendar.locale?.identifier ?? Locale.current.identifier).hasPrefix("en_US")
        if a > 12 && b <= 12 { return (month: b, day: a) }
        if b > 12 && a <= 12 { return (month: a, day: b) }
        return usesUSFormat ? (month: a, day: b) : (month: b, day: a)
    }

    static func makeYearAwareDate(month: Int, day: Int, now: Date, calendar: Calendar) -> Date? {
        var comps = DateComponents()
        comps.year = calendar.component(.year, from: now)
        comps.month = month
        comps.day = day
        comps.hour = 0
        comps.minute = 0
        guard let candidate = calendar.date(from: comps) else { return nil }
        if candidate < calendar.startOfDay(for: now) {
            comps.year = (comps.year ?? 0) + 1
            return calendar.date(from: comps)
        }
        return candidate
    }
}
