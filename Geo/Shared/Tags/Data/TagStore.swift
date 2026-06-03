import Foundation
import Combine
import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "TagStore")

@MainActor
class TagStore: ObservableObject {
    static let shared = TagStore()

    @Published private(set) var tags: [Tag] = []

    private let fileManager = FileManager.default
    private let tagsURL: URL
    private let queue = DispatchQueue(label: "com.geo.tagstore", qos: .userInitiated)
    private var fileWatcher: FileWatcherService?
    private var lastWriteTime: Date = .distantPast
    private let externalWriteGracePeriod: TimeInterval = 0.6

    init(baseURL: URL? = nil, enableWatcher: Bool = true) {
        let base = baseURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let directory = base.appendingPathComponent("Geo", isDirectory: true)
        tagsURL = directory.appendingPathComponent("tags.json")

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        loadTags()

        if enableWatcher {
            let watcher = FileWatcherService(url: directory, latency: 2.0)
            watcher.onChange = { [weak self] (urls: [URL]) in
                Task { @MainActor [weak self] in
                    self?.handleExternalChanges(urls)
                }
            }
            watcher.start()
            fileWatcher = watcher
        }
    }

    @discardableResult
    func createTag(name: String, color: TagColor) -> Result<Tag, TagStoreError> {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("TagStore", operation: "create")
        defer { PerformanceTracker.shared.endStoreOperation("TagStore", operation: "create", signpostID: spID, startTime: spStart) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyName) }
        guard isUniqueName(trimmed) else { return .failure(.duplicateName) }

        let tag = Tag(id: UUID().uuidString, name: trimmed, color: color)
        tags.append(tag)

        lastWriteTime = Date()
        let snapshot = tags
        queue.async {
            self.saveTags(snapshot)
        }

        return .success(tag)
    }

    @discardableResult
    func deleteTag(id: String) -> Bool {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("TagStore", operation: "delete")
        defer { PerformanceTracker.shared.endStoreOperation("TagStore", operation: "delete", signpostID: spID, startTime: spStart) }
        guard let index = tags.firstIndex(where: { $0.id == id }) else { return false }
        tags.remove(at: index)

        lastWriteTime = Date()
        let snapshot = tags
        queue.async {
            self.saveTags(snapshot)
        }

        return true
    }

    @discardableResult
    func updateTag(id: String, name: String, color: TagColor) -> Result<Tag, TagStoreError> {
        let spStart = CFAbsoluteTimeGetCurrent()
        let spID = PerformanceTracker.shared.beginStoreOperation("TagStore", operation: "update")
        defer { PerformanceTracker.shared.endStoreOperation("TagStore", operation: "update", signpostID: spID, startTime: spStart) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyName) }
        guard let index = tags.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }
        guard isUniqueName(trimmed, excluding: id) else { return .failure(.duplicateName) }

        tags[index].name = trimmed
        tags[index].color = color

        lastWriteTime = Date()
        let snapshot = tags
        queue.async {
            self.saveTags(snapshot)
        }

        return .success(tags[index])
    }

    func tag(for id: String?) -> Tag? {
        guard let id else { return nil }
        return tags.first { $0.id == id }
    }

    func tag(forName name: String) -> Tag? {
        let canonical = Self.canonicalName(name)
        return tags.first { Self.canonicalName($0.name) == canonical }
    }

    func color(forName name: String) -> TagColor? {
        tag(forName: name)?.color
    }

    @discardableResult
    func ensureColor(forName rawName: String) -> Tag {
        let canonical = Self.canonicalName(rawName)
        if let existing = tag(forName: canonical) {
            return existing
        }
        let tag = Tag(id: UUID().uuidString, name: canonical, color: Self.defaultColor(forName: canonical))
        tags.append(tag)
        lastWriteTime = Date()
        let snapshot = tags
        queue.async { self.saveTags(snapshot) }
        return tag
    }

    nonisolated static func defaultColor(forName name: String) -> TagColor {
        let hue = Double(abs(name.hashValue) % 360) / 360.0
        let nsColor = NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1.0)
        return TagColor(
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent),
            alpha: 1.0
        )
    }

    private func loadTags() {
        guard fileManager.fileExists(atPath: tagsURL.path) else { return }
        do {
            let data = try Data(contentsOf: tagsURL)
            tags = try Self.decodeTags(data)
        } catch {
            logger.error("Failed to load tags: \(error.localizedDescription)")
        }
    }

    nonisolated static func decodeTags(_ data: Data) throws -> [Tag] {
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode([Tag].self, from: data) {
            return legacy
        }
        let shrunk = try decoder.decode([String: TagColorEntry].self, from: data)
        return shrunk
            .sorted { ($0.value.order ?? Int.max, $0.key) < ($1.value.order ?? Int.max, $1.key) }
            .map { Tag(id: UUID().uuidString, name: $0.key, color: $0.value.color) }
    }

    nonisolated private func saveTags(_ snapshot: [Tag]) {
        do {
            var entries: [String: TagColorEntry] = [:]
            for (index, tag) in snapshot.enumerated() {
                entries[Self.canonicalName(tag.name)] = TagColorEntry(color: tag.color, icon: nil, order: index)
            }
            let data = try JSONEncoder().encode(entries)
            try data.write(to: tagsURL, options: .atomic)
        } catch {
            logger.error("Failed to save tags: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleExternalChanges(_ urls: [URL]) {
        let tagsChanged = urls.contains { $0.lastPathComponent == "tags.json" }
        guard tagsChanged else { return }
        guard Date().timeIntervalSince(lastWriteTime) >= externalWriteGracePeriod else { return }
        loadTags()
    }

    private func isUniqueName(_ name: String, excluding excludedId: String? = nil) -> Bool {
        let normalized = Self.canonicalName(name)
        return !tags.contains { tag in
            if let excludedId, tag.id == excludedId {
                return false
            }
            return Self.canonicalName(tag.name) == normalized
        }
    }

    nonisolated static func canonicalName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}

struct TagColorEntry: Codable, Hashable {
    let color: TagColor
    let icon: String?
    let order: Int?
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
