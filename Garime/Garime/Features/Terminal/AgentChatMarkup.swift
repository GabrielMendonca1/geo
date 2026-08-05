import SwiftUI

enum AgentChatSpan: Equatable {
    case text(String)
    case code(String)
}

enum AgentChatChunk: Equatable {
    case prose(String)
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

    static func spans(_ raw: String) -> [AgentChatSpan] {
        guard raw.contains("`") else { return [.text(raw)] }
        var spans: [AgentChatSpan] = []
        var pending = ""
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "`") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "`") else { break }
            let inner = String(rest[after..<close])
            let tail = rest.index(after: close)
            guard !inner.isEmpty else {
                pending += String(rest[..<tail])
                rest = rest[tail...]
                continue
            }
            pending += String(rest[..<open])
            if !pending.isEmpty {
                spans.append(.text(pending))
                pending = ""
            }
            spans.append(.code(inner))
            rest = rest[tail...]
        }
        pending += String(rest)
        if !pending.isEmpty { spans.append(.text(pending)) }
        return spans.isEmpty ? [.text(raw)] : spans
    }

    static func code(in raw: String) -> String {
        chunks(raw)
            .compactMap { if case .code(let body) = $0 { return body } else { return nil } }
            .joined(separator: "\n\n")
    }

    static func attributed(_ raw: String) -> AttributedString {
        var out = AttributedString()
        for span in spans(raw) {
            switch span {
            case .text(let value):
                out.append(AttributedString(value))
            case .code(let value):
                var chunk = AttributedString(value)
                chunk.backgroundColor = Color.slateInk(0.12)
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
