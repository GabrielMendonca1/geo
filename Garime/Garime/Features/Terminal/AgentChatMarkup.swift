import SwiftUI

enum AgentChatSpan: Equatable {
    case text(String)
    case code(String)
    case strong(String)
    case emphasis(String)
    case link(String)
}

enum AgentChatChunk: Equatable {
    case prose(String)
    case code(String)
}

enum AgentChatBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case bullet(String)
    case ordered(String, String)
    case code(String)
}

enum AgentChatMarkup {
    static func chunks(_ raw: String) -> [AgentChatChunk] {
        guard raw.contains("```") else { return prose(raw) }
        var result: [AgentChatChunk] = []
        var plain: [String] = []
        var block: [String] = []
        var fenced = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if fenced {
                    append(code: block, into: &result)
                    block = []
                } else {
                    append(prose: plain, into: &result)
                    plain = []
                }
                fenced.toggle()
                continue
            }
            if fenced { block.append(line) } else { plain.append(line) }
        }
        if fenced {
            append(code: block, into: &result)
        } else {
            append(prose: plain, into: &result)
        }
        return result
    }

    static func blocks(_ raw: String) -> [AgentChatBlock] {
        chunks(raw).flatMap { chunk -> [AgentChatBlock] in
            switch chunk {
            case .code(let body): return [.code(body)]
            case .prose(let body): return proseBlocks(body)
            }
        }
    }

    static func spans(_ raw: String) -> [AgentChatSpan] {
        guard raw.contains("`") || raw.contains("*") || raw.contains("[") else { return [.text(raw)] }
        var spans: [AgentChatSpan] = []
        var pending = ""
        var index = raw.startIndex
        func flush() {
            guard !pending.isEmpty else { return }
            spans.append(.text(pending))
            pending = ""
        }
        while index < raw.endIndex {
            if let (span, next) = inline(raw, at: index) {
                flush()
                spans.append(span)
                index = next
                continue
            }
            pending.append(raw[index])
            index = raw.index(after: index)
        }
        flush()
        return spans.isEmpty ? [.text(raw)] : spans
    }

    private static func inline(_ raw: String, at index: String.Index) -> (AgentChatSpan, String.Index)? {
        switch raw[index] {
        case "`":
            guard let (inner, next) = delimited(raw, at: index, marker: "`") else { return nil }
            return (.code(inner), next)
        case "*":
            if raw[index...].hasPrefix("**"),
               let (inner, next) = delimited(raw, at: index, marker: "**"),
               tight(inner) {
                return (.strong(inner), next)
            }
            guard let (inner, next) = delimited(raw, at: index, marker: "*"), tight(inner) else { return nil }
            return (.emphasis(inner), next)
        case "[":
            guard let (label, next) = link(raw, at: index) else { return nil }
            return (.link(label), next)
        default:
            return nil
        }
    }

    private static func tight(_ inner: String) -> Bool {
        guard let first = inner.first, let last = inner.last else { return false }
        return !first.isWhitespace && !last.isWhitespace
    }

    private static func delimited(_ raw: String, at index: String.Index, marker: String) -> (String, String.Index)? {
        guard let start = raw.index(index, offsetBy: marker.count, limitedBy: raw.endIndex), start < raw.endIndex,
              let close = raw.range(of: marker, range: start..<raw.endIndex)
        else { return nil }
        let inner = String(raw[start..<close.lowerBound])
        guard !inner.isEmpty, !inner.contains("\n") else { return nil }
        return (inner, close.upperBound)
    }

    private static func link(_ raw: String, at index: String.Index) -> (String, String.Index)? {
        let start = raw.index(after: index)
        guard start < raw.endIndex,
              let middle = raw.range(of: "](", range: start..<raw.endIndex),
              let close = raw.range(of: ")", range: middle.upperBound..<raw.endIndex)
        else { return nil }
        let label = String(raw[start..<middle.lowerBound])
        guard !label.isEmpty, !label.contains("\n"), !label.contains("[") else { return nil }
        return (label, close.upperBound)
    }

    private static func proseBlocks(_ body: String) -> [AgentChatBlock] {
        var result: [AgentChatBlock] = []
        var para: [String] = []
        func flush() {
            let text = para.joined(separator: "\n").trimmingCharacters(in: .newlines)
            para = []
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            result.append(.paragraph(text))
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let block = heading(line) ?? item(line) {
                flush()
                result.append(block)
                continue
            }
            para.append(line)
        }
        flush()
        return result
    }

    private static func heading(_ line: String) -> AgentChatBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(hashes, text)
    }

    private static func item(_ line: String) -> AgentChatBlock? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 7 else { return nil }
        let body = line.dropFirst(indent)
        if let first = body.first, first == "-" || first == "*" {
            let rest = body.dropFirst()
            guard rest.hasPrefix(" ") else { return nil }
            let text = rest.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .bullet(text)
        }
        let digits = body.prefix(while: \.isNumber)
        guard (1...3).contains(digits.count) else { return nil }
        let rest = body.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .ordered(String(digits) + ".", text)
    }

    static func code(in raw: String) -> String {
        chunks(raw)
            .compactMap { if case .code(let body) = $0 { return body } else { return nil } }
            .joined(separator: "\n\n")
    }

    static func attributed(_ raw: String, base: Font = .body) -> AttributedString {
        var out = AttributedString()
        for span in spans(raw) {
            switch span {
            case .text(let value):
                out.append(AttributedString(value))
            case .code(let value):
                var chunk = AttributedString(value)
                chunk.backgroundColor = Color.slateInk(0.12)
                chunk.font = .system(.body, design: .monospaced)
                out.append(chunk)
            case .strong(let value):
                var chunk = AttributedString(value)
                chunk.font = base.bold()
                out.append(chunk)
            case .emphasis(let value):
                var chunk = AttributedString(value)
                chunk.font = base.italic()
                out.append(chunk)
            case .link(let value):
                var chunk = AttributedString(value)
                chunk.foregroundColor = .accentColor
                chunk.underlineStyle = .single
                out.append(chunk)
            }
        }
        return out
    }

    private static func prose(_ raw: String) -> [AgentChatChunk] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [.prose(trimmed)]
    }

    private static func append(prose lines: [String], into result: inout [AgentChatChunk]) {
        result.append(contentsOf: prose(lines.joined(separator: "\n")))
    }

    private static func append(code lines: [String], into result: inout [AgentChatChunk]) {
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        result.append(.code(body))
    }
}

enum AgentChatClock {
    static let gap: TimeInterval = 900

    static func date(_ ts: String) -> Date? {
        let raw = ts.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        if let date = isoFormatter.date(from: raw) { return date }
        if let seconds = TimeInterval(raw), seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        return localFormatter.date(from: raw)
    }

    static func label(_ ts: String, now: Date = Date()) -> String {
        guard let date = date(ts) else { return "" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return hourFormatter.string(from: date)
        }
        return dayFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let localFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MM HH:mm"
        return formatter
    }()
}

enum AgentChatEmpty {
    static func text(loaded: Bool, reachable: Bool, noAgent: Bool) -> String {
        if noAgent { return "esse agente não existe mais" }
        if !reachable { return "sem conexão com o mac" }
        if !loaded { return "carregando…" }
        return "sem mensagens ainda"
    }
}
