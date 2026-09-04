import Foundation

struct ProcessOutcome {
    let status: Int32
    let output: String
    let error: String
    let timedOut: Bool
    let cancelled: Bool

    var trimmedError: String {
        let value = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "status inesperado" : String(value.prefix(160))
    }

    static let aborted = ProcessOutcome(
        status: -1,
        output: "",
        error: "",
        timedOut: false,
        cancelled: true
    )
}

final class ProcessRunner {
    private let watchdog = DispatchQueue(label: "ai.garime.whisper.runner.watchdog")
    private let lock = NSLock()
    private var current: Process?
    private var cancelled = false
    private var expired = false

    func reset() {
        lock.lock()
        cancelled = false
        expired = false
        current = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = current
        lock.unlock()
        process?.terminate()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> ProcessOutcome {
        if isCancelled { return ProcessOutcome.aborted }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()

        lock.lock()
        current = process
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { process.terminate() }

        let deadline = DispatchWorkItem { [weak self] in
            guard let self, process.isRunning else { return }
            self.lock.lock()
            self.expired = true
            self.lock.unlock()
            process.terminate()
        }
        watchdog.asyncAfter(deadline: .now() + timeout, execute: deadline)

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            outData = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(group: group) {
            errData = err.fileHandleForReading.readDataToEndOfFile()
        }
        group.wait()
        process.waitUntilExit()
        deadline.cancel()

        lock.lock()
        current = nil
        let didExpire = expired
        let didCancel = cancelled
        lock.unlock()

        return ProcessOutcome(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            error: String(decoding: errData, as: UTF8.self),
            timedOut: didExpire,
            cancelled: didCancel && !didExpire
        )
    }
}
