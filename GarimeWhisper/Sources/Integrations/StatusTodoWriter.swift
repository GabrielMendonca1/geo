import Foundation

enum StatusTodoWriter {
    static func complete(markdown: String, todo: String, on day: String) -> String? {
        var lines = markdown.components(separatedBy: "\n")
        var todoIndex: Int?
        var section = ""
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                section = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard section == "todo", trimmed.hasPrefix("- [ ]") else { continue }
            let text = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if text == todo {
                todoIndex = index
                break
            }
        }
        guard let todoIndex else { return nil }
        lines.remove(at: todoIndex)

        let entry = "- [x] \(todo) (\(day))"
        var doneIndex: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("## ") else { continue }
            if trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "feito" {
                doneIndex = index
                break
            }
        }
        if let doneIndex {
            var insertAt = doneIndex + 1
            while insertAt < lines.count,
                  lines[insertAt].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt += 1
            }
            lines.insert(entry, at: insertAt)
        } else {
            if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                lines.append("")
            }
            lines.append("## Feito")
            lines.append(entry)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    @discardableResult
    static func complete(path: String, todo: String, now: Date = Date()) -> Bool {
        guard let markdown = try? String(contentsOfFile: path, encoding: .utf8),
              let updated = complete(markdown: markdown, todo: todo, on: stamp(now))
        else { return false }
        let temporary = path + ".garime-tmp"
        do {
            try updated.write(toFile: temporary, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path),
                withItemAt: URL(fileURLWithPath: temporary)
            )
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            return false
        }
    }
}
