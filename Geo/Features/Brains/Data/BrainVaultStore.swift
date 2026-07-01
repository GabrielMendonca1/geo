import Foundation

// MARK: - File-native model (~/Geo/Brains/<name>/ vaults are the source of truth)

struct BrainMeta: Codable {
    var id: String
    var title: String
    var gist: String
    var created: String?
    var updated: String?
    var nodes: Int?
    var sources: [String]?
}

struct BrainVault: Identifiable, Hashable {
    let id: String
    let title: String
    let gist: String
    let noteCount: Int
    let sourceCount: Int
    let folder: URL
    var ready: Bool { noteCount > 0 }
}

struct BrainNote: Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    let url: URL
}

@MainActor
final class BrainVaultStore: ObservableObject {
    @Published var vaults: [BrainVault] = []

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Geo/Brains", isDirectory: true)

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [BrainVault] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let meta = Self.meta(in: dir) else { continue }
            found.append(BrainVault(
                id: meta.id, title: meta.title, gist: meta.gist,
                noteCount: Self.noteFiles(in: dir).count,
                sourceCount: Self.sourceFiles(in: dir).count,
                folder: dir
            ))
        }
        vaults = found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    nonisolated static func meta(in folder: URL) -> BrainMeta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".brain.json")) else { return nil }
        return try? JSONDecoder().decode(BrainMeta.self, from: data)
    }

    nonisolated static func noteFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "index.md" }
    }

    nonisolated static func sourceFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("sources"), includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
    }

    nonisolated static func notes(in vault: BrainVault) -> [BrainNote] {
        noteFiles(in: vault.folder).compactMap { url in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let body = stripFrontmatter(raw)
            return BrainNote(id: url.deletingPathExtension().lastPathComponent, title: titleOf(body, fallback: url.deletingPathExtension().lastPathComponent), body: body, url: url)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    func create(name: String, gist: String) throws -> BrainVault {
        let id = Self.slug(name)
        let dir = Self.root.appendingPathComponent(id, isDirectory: true)
        if vaults.contains(where: { $0.id == id }) || FileManager.default.fileExists(atPath: dir.path) {
            throw BrainVaultError.exists(id)
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sources"), withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter().string(from: Date())
        try Self.writeMeta(BrainMeta(id: id, title: name, gist: gist, created: iso, updated: iso, nodes: 0, sources: []), to: dir)
        VaultIngest.rebuildIndex(in: dir, title: name, gist: gist)
        reload()
        return vaults.first { $0.id == id } ?? BrainVault(id: id, title: name, gist: gist, noteCount: 0, sourceCount: 0, folder: dir)
    }

    // Creates an empty note `.md` in the vault (unique filename) and returns its slug id.
    @discardableResult
    func createNote(in vault: BrainVault, title: String = "Untitled") throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "Untitled" : trimmed
        let base = Self.slug(display)
        var id = base
        var n = 2
        var url = vault.folder.appendingPathComponent("\(id).md")
        while FileManager.default.fileExists(atPath: url.path) {
            id = "\(base)-\(n)"; n += 1
            url = vault.folder.appendingPathComponent("\(id).md")
        }
        try "# \(display)\n\n".write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    nonisolated static func slug(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        return String(lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }).split(separator: "-").joined(separator: "-")
    }

    nonisolated static func writeMeta(_ meta: BrainMeta, to folder: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: folder.appendingPathComponent(".brain.json"))
    }

    nonisolated static func stripFrontmatter(_ raw: String) -> String {
        guard raw.hasPrefix("---") else { return raw }
        let lines = raw.components(separatedBy: "\n")
        var idx = 1
        while idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces) != "---" { idx += 1 }
        return lines.dropFirst(idx + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func titleOf(_ body: String, fallback: String) -> String {
        for line in body.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { return String(t.drop(while: { $0 == "#" }).drop(while: { $0 == " " })) }
        }
        return fallback
    }
}

enum BrainVaultError: LocalizedError {
    case exists(String)
    var errorDescription: String? {
        switch self {
        case .exists(let id): return "A brain named \u{201C}\(id)\u{201D} already exists. Pick a different name."
        }
    }
}
