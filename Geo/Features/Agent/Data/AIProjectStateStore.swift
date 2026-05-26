import Foundation

struct AIProjectStoredState: Codable, Hashable {
    var enabledAgents: [AIAgentKind]
    var trustedForAutomation: Bool
}

actor AIProjectStateStore {
    static let shared = AIProjectStateStore()

    private struct Disk: Codable {
        var byRemote: [String: AIProjectStoredState]
        var byPath: [String: AIProjectStoredState]
    }

    private let fileURL: URL
    private var cache: Disk
    private var loaded = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            self.fileURL = appSupport
                .appendingPathComponent("Geo/Symphony", isDirectory: true)
                .appendingPathComponent("project_state.json")
        }
        self.cache = Disk(byRemote: [:], byPath: [:])
    }

    func load(remote: String?, path: String) -> AIProjectStoredState? {
        ensureLoaded()
        if let key = canonicalRemoteKey(remote), let state = cache.byRemote[key] {
            return state
        }
        return cache.byPath[canonicalPathKey(path)]
    }

    func save(remote: String?, path: String, state: AIProjectStoredState) {
        ensureLoaded()
        if let key = canonicalRemoteKey(remote) {
            cache.byRemote[key] = state
        }
        cache.byPath[canonicalPathKey(path)] = state
        flush()
    }

    func remove(remote: String?, path: String) {
        ensureLoaded()
        if let key = canonicalRemoteKey(remote) {
            cache.byRemote.removeValue(forKey: key)
        }
        cache.byPath.removeValue(forKey: canonicalPathKey(path))
        flush()
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(Disk.self, from: data) {
            cache = decoded
        }
    }

    private func flush() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cache) else { return }
        let tempURL = directory.appendingPathComponent(".project_state.json.\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func canonicalRemoteKey(_ remote: String?) -> String? {
        guard let remote else { return nil }
        var trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix(".git") {
            trimmed = String(trimmed.dropLast(4))
        }
        if let range = trimmed.range(of: "://") {
            trimmed = String(trimmed[range.upperBound...])
        } else if trimmed.contains("@") {
            if let atIndex = trimmed.firstIndex(of: "@") {
                trimmed = String(trimmed[trimmed.index(after: atIndex)...])
            }
            trimmed = trimmed.replacingOccurrences(of: ":", with: "/")
        }
        return trimmed.lowercased()
    }

    private func canonicalPathKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
