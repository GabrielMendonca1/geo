import Foundation

struct VaultTask: Equatable {
    let id: String
    let title: String
    let status: String
    let priority: String
    let due: Date?
    let reminders: Int

    var isOpen: Bool { status != "completed" }
}

enum VaultTasks {
    static func split(concatenated data: Data) -> [Data] {
        var chunks: [Data] = []
        var depth = 0
        var start: Int?
        var inString = false
        var escaped = false
        let bytes = [UInt8](data)
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"):
                if depth == 0 { start = index }
                depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0, let opened = start {
                    chunks.append(data.subdata(in: opened..<(index + 1)))
                    start = nil
                }
                if depth < 0 { depth = 0 }
            default:
                break
            }
        }
        return chunks
    }

    static func decode(_ chunk: Data) -> VaultTask? {
        guard let object = try? JSONSerialization.jsonObject(with: chunk),
              let dict = object as? [String: Any],
              let title = dict["title"] as? String
        else { return nil }
        let body = dict["body"] as? [String: Any]
        var due: Date?
        if let raw = (body?["due"] as? String) ?? (dict["due"] as? String) {
            let formatter = ISO8601DateFormatter()
            due = formatter.date(from: raw)
        }
        return VaultTask(
            id: dict["id"] as? String ?? "",
            title: title,
            status: dict["status"] as? String ?? "",
            priority: dict["priority"] as? String ?? "unset",
            due: due,
            reminders: (dict["reminders"] as? [Any])?.count ?? 0
        )
    }

    static func parse(_ data: Data) -> [VaultTask] {
        split(concatenated: data).compactMap(decode)
    }

    static func priorityRank(_ priority: String) -> Int {
        switch priority {
        case "high", "alta": return 0
        case "medium", "media": return 1
        case "low", "baixa": return 2
        default: return 3
        }
    }

    static func open(_ tasks: [VaultTask]) -> [VaultTask] {
        tasks.filter(\.isOpen).sorted { lhs, rhs in
            switch (lhs.due, rhs.due) {
            case (let left?, let right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }
            let leftRank = priorityRank(lhs.priority)
            let rightRank = priorityRank(rhs.priority)
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func age(from origin: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(origin))
        if seconds < 90 { return "agora" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "há \(minutes) min" }
        let hours = Int(seconds / 3600)
        if hours < 48 { return "há \(hours) h" }
        return "há \(Int(seconds / 86400)) d"
    }

    static func dueLabel(_ due: Date?, calendar: Calendar = .current) -> String? {
        guard let due else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "dd/MM"
        return formatter.string(from: due)
    }
}
