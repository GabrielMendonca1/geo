import Foundation
import SwiftUI

struct JobSpec: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let cron: String
    let prompt: String
    let sinks: [String]
}

struct Job: Identifiable, Equatable {
    let spec: JobSpec
    let runtime: JobRuntime?
    var id: String { spec.id }
}

@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [Job] = []

    private let runtimeLookup: ((String) -> JobRuntime?)?
    private var watcher: DispatchSourceFileSystemObject?
    private let watcherQueue = DispatchQueue(label: "ai.geo.jobstore.watch", qos: .utility)

    init(runtimeLookup: ((String) -> JobRuntime?)? = nil) {
        self.runtimeLookup = runtimeLookup
        try? ClawSignalBus.ensureJobsDir()
        reload()
        installWatcher()
    }

    deinit {
        watcher?.cancel()
    }

    func refresh() {
        reload()
    }

    func add(_ spec: JobSpec) throws {
        try ClawSignalBus.ensureJobsDir()
        let url = ClawSignalBus.jobsDirURL().appendingPathComponent("\(spec.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(spec)
        try data.write(to: url, options: .atomic)
        try ClawSignalBus.writeSignal(name: "add-job:\(spec.id)")
        reload()
    }

    func remove(_ id: String) throws {
        let url = ClawSignalBus.jobsDirURL().appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
        try ClawSignalBus.writeSignal(name: "remove-job:\(id)")
        reload()
    }

    private func reload() {
        let dir = ClawSignalBus.jobsDirURL()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            jobs = []
            return
        }
        let decoder = JSONDecoder()
        var loaded: [Job] = []
        for url in entries where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let spec = try? decoder.decode(JobSpec.self, from: data) else { continue }
            loaded.append(Job(spec: spec, runtime: runtimeLookup?(spec.id)))
        }
        loaded.sort { $0.spec.title.localizedCaseInsensitiveCompare($1.spec.title) == .orderedAscending }
        jobs = loaded
    }

    private func installWatcher() {
        let path = ClawSignalBus.jobsDirURL().path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: watcherQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.reload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}

enum JobSlug {
    static func make(_ raw: String) -> String {
        let lower = raw.lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in lower.unicodeScalars {
            let isAlnum = CharacterSet.alphanumerics.contains(scalar)
            if isAlnum {
                result.append(Character(scalar))
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        if result.isEmpty { result = "job" }
        return result
    }

    static func jobID(from title: String) -> String {
        "\(make(title))-\(Int(Date().timeIntervalSince1970))"
    }
}
