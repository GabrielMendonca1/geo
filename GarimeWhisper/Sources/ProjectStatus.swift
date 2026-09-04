import Foundation

struct ProjectStatus: Equatable {
    let name: String
    let updated: String?
    let todos: [String]
    let path: String
}

enum ProjectStatusScanner {
    static func parse(markdown: String, fallbackName: String, path: String) -> ProjectStatus {
        var name = fallbackName
        var updated: String?
        var todos: [String] = []
        var inTodo = false
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                let heading = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if let range = heading.range(of: "STATUS"), heading.startIndex == range.lowerBound {
                    let tail = heading[range.upperBound...]
                        .trimmingCharacters(in: CharacterSet(charactersIn: " —–-"))
                    if !tail.isEmpty { name = tail }
                }
                continue
            }
            if updated == nil, line.hasPrefix(">") {
                let quoted = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if quoted.lowercased().hasPrefix("atualizado:") {
                    let value = quoted.dropFirst("atualizado:".count)
                        .trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { updated = value }
                }
                continue
            }
            if line.hasPrefix("## ") {
                let section = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                inTodo = section == "todo"
                continue
            }
            guard inTodo else { continue }
            if line.hasPrefix("- [ ]") {
                let text = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { todos.append(text) }
            }
        }
        return ProjectStatus(name: name, updated: updated, todos: todos, path: path)
    }

    static func statusFiles(under root: String) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        let direct = root + "/STATUS.md"
        if fm.fileExists(atPath: direct) { found.append(direct) }
        let entries = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        for entry in entries.sorted() {
            guard !entry.hasPrefix(".") else { continue }
            let nested = root + "/" + entry + "/STATUS.md"
            var isDirectory = ObjCBool(false)
            guard fm.fileExists(atPath: root + "/" + entry, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fm.fileExists(atPath: nested)
            else { continue }
            found.append(nested)
        }
        return found
    }

    static func scan(roots: [String]) -> [ProjectStatus] {
        var results: [ProjectStatus] = []
        for root in roots {
            for file in statusFiles(under: root) {
                guard let markdown = try? String(contentsOfFile: file, encoding: .utf8) else {
                    continue
                }
                let parent = (file as NSString).deletingLastPathComponent
                let fallback = (parent as NSString).lastPathComponent
                let status = parse(markdown: markdown, fallbackName: fallback, path: file)
                if !status.todos.isEmpty { results.append(status) }
            }
        }
        return results
    }
}
