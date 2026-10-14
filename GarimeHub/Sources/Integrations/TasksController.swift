import Foundation

final class TasksController {
    private let runner = ProcessRunner()
    private let queue = DispatchQueue(label: "ai.garime.hub.tasks")
    private var running = false
    private var generation = 0
    private var fetching = false

    private(set) var tasks: [VaultTask] = []
    private(set) var fetchedAt: Date?
    private(set) var offline = false
    var onChange: (() -> Void)?

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        loadCache()
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        fetching = false
        runner.cancel()
    }

    func refreshIfStale() {
        guard let fetchedAt else {
            refresh()
            return
        }
        if Date().timeIntervalSince(fetchedAt) > Config.tasksStaleAfter {
            refresh()
        }
    }

    func refresh() {
        guard running, !fetching else { return }
        fetching = true
        let requestGeneration = generation
        queue.async { [weak self] in
            guard let self, self.running, self.generation == requestGeneration else { return }
            self.runner.reset()
            let outcome = try? self.runner.run(
                Config.sshBinary,
                [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=5",
                    Config.tasksHost,
                    "cat " + Config.tasksRemoteGlob,
                ],
                timeout: Config.tasksFetchTimeout
            )
            DispatchQueue.main.async {
                guard self.running, self.generation == requestGeneration else { return }
                self.fetching = false
                if let outcome, outcome.status == 0, !outcome.output.isEmpty {
                    self.tasks = VaultTasks.parse(Data(outcome.output.utf8))
                    self.fetchedAt = Date()
                    self.offline = false
                    self.writeCache(outcome.output)
                } else {
                    self.offline = true
                }
                self.onChange?()
            }
        }
    }

    private var cachePath: String { Config.hubDirectory + "/tasks-cache.raw" }

    private func loadCache() {
        guard let raw = try? String(contentsOfFile: cachePath, encoding: .utf8) else { return }
        tasks = VaultTasks.parse(Data(raw.utf8))
        fetchedAt = (try? FileManager.default.attributesOfItem(atPath: cachePath))?[.modificationDate] as? Date
        offline = true
        onChange?()
    }

    private func writeCache(_ raw: String) {
        try? FileManager.default.createDirectory(
            atPath: Config.hubDirectory,
            withIntermediateDirectories: true
        )
        try? raw.write(toFile: cachePath, atomically: true, encoding: .utf8)
    }
}
