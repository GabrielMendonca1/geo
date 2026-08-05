import Foundation

public enum LenientDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let internetDateTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let naive: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let d = internetDateTime.date(from: s) { return d }
        if let d = fractional.date(from: s) { return d }
        if let d = naive.date(from: s) { return d }
        if let d = dateOnly.date(from: s) {
            return Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: d) ?? d
        }
        return nil
    }

    public static let decodingStrategy = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let c = try decoder.singleValueContainer()
        if let raw = try? c.decode(String.self) {
            if let date = parse(raw) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unparseable date: \(raw)")
        }
        if let seconds = try? c.decode(Double.self) {
            return Date(timeIntervalSince1970: seconds)
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported date value")
    }
}
