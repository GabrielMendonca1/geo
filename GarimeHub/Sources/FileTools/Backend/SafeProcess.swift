import Foundation
import Darwin

final class FileToolsCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var committed = false
    private let deadline: UInt64

    init(timeout: TimeInterval) {
        let now = DispatchTime.now().uptimeNanoseconds
        let capacity = UInt64.max - now
        let scaled = (timeout * 1_000_000_000).rounded(.down)
        let representable = UInt64(exactly: scaled) ?? capacity
        deadline = now + min(representable, capacity)
    }

    func attach(_ value: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        process = value
        return cancelled
    }

    func detach(_ value: Process) {
        lock.lock()
        if process === value { process = nil }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !committed else { lock.unlock(); return }
        cancelled = true
        let value = process
        lock.unlock()
        terminateAndEscalate(value)
    }

    func authorizeCommit() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw FileToolsError.cancelled }
        if DispatchTime.now().uptimeNanoseconds >= deadline { throw FileToolsError.timedOut }
        committed = true
        process = nil
    }

    func checkpoint() throws {
        if isCancelled { throw FileToolsError.cancelled }
        if DispatchTime.now().uptimeNanoseconds >= deadline { throw FileToolsError.timedOut }
    }

    func remaining() throws -> TimeInterval {
        if isCancelled { throw FileToolsError.cancelled }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw FileToolsError.timedOut }
        return TimeInterval(deadline - now) / 1_000_000_000
    }

    private func terminateAndEscalate(_ value: Process?) {
        guard let value else { return }
        value.terminate()
        let pid = value.processIdentifier
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self, weak value] in
            guard let self, let value else { return }
            self.lock.lock()
            let stillAttached = self.process === value
            self.lock.unlock()
            if stillAttached && value.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

private final class OutputBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var exceeded = false
    func markExceeded() { lock.lock(); exceeded = true; lock.unlock() }
    func value() -> Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
}

private final class CappedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var exceeded = false
    let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !exceeded else { return }
        if data.count + chunk.count > limit {
            exceeded = true
            data.append(chunk.prefix(max(0, limit - data.count)))
        } else {
            data.append(chunk)
        }
    }

    func isExceeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return exceeded
    }

    func string() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

struct SafeProcessOutput {
    let stdout: String
    let stderr: String
}

enum SafeProcess {
    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        textLimit: Int = 1_048_576,
        outputDirectory: URL? = nil,
        maximumOutputBytes: Int64 = .max,
        currentDirectory: URL? = nil,
        cancellation: FileToolsCancellation
    ) throws -> SafeProcessOutput {
        guard timeout > 0 else { throw FileToolsError.invalidRequest("timeout deve ser positivo") }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        let temporaryDirectory = FileManager.default.temporaryDirectory.path
        if temporaryDirectory.hasPrefix("/") { environment["TMPDIR"] = temporaryDirectory }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdout = CappedData(limit: textLimit), stderr = CappedData(limit: textLimit)
        let stdoutReader = stdoutPipe.fileHandleForReading
        let stderrReader = stderrPipe.fileHandleForReading
        let stdoutFD = stdoutReader.fileDescriptor
        let stderrFD = stderrReader.fileDescriptor
        _ = fcntl(stdoutFD, F_SETFL, fcntl(stdoutFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(stderrFD, F_SETFL, fcntl(stderrFD, F_GETFL) | O_NONBLOCK)

        do { try process.run() } catch {
            try? stdoutReader.close()
            try? stderrReader.close()
            throw FileToolsError.processFailed("não foi possível iniciar \(executable.path): \(error.localizedDescription)")
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        defer {
            try? stdoutReader.close()
            try? stderrReader.close()
        }

        if cancellation.attach(process) { process.terminate() }
        let budget = OutputBudget()
        var budgetTimer: DispatchSourceTimer?
        if let outputDirectory, maximumOutputBytes < Int64.max {
            let monitor = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            monitor.schedule(deadline: .now() + 0.1, repeating: 0.1)
            monitor.setEventHandler {
                var size: Int64 = 0
                if let items = FileManager.default.enumerator(at: outputDirectory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let item as URL in items {
                        let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        if values?.isRegularFile == true { size += Int64(values?.fileSize ?? 0) }
                        if size > maximumOutputBytes {
                            budget.markExceeded()
                            process.terminate()
                            break
                        }
                    }
                }
            }
            monitor.resume()
            budgetTimer = monitor
        }
        defer { budgetTimer?.cancel() }

        let start = DispatchTime.now().uptimeNanoseconds
        let capacity = UInt64.max - start
        let scaled = (timeout * 1_000_000_000).rounded(.down)
        let representable = UInt64(exactly: scaled) ?? capacity
        let end = start + min(representable, capacity)
        var timedOut = false
        var stopRequested = false
        var killAt: UInt64?
        var descriptors = [
            pollfd(fd: stdoutFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
            pollfd(fd: stderrFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
        ]

        while process.isRunning {
            _ = poll(&descriptors, nfds_t(descriptors.count), 50)
            drain(stdoutFD, into: stdout)
            drain(stderrFD, into: stderr)
            let now = DispatchTime.now().uptimeNanoseconds
            if cancellation.isCancelled || budget.value() || stdout.isExceeded() || stderr.isExceeded() || now >= end {
                if now >= end { timedOut = true }
                if !stopRequested {
                    process.terminate()
                    stopRequested = true
                    killAt = now + 500_000_000
                }
            }
            if let killAt, now >= killAt, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        cancellation.detach(process)
        drain(stdoutFD, into: stdout)
        drain(stderrFD, into: stderr)

        if cancellation.isCancelled { throw FileToolsError.cancelled }
        if budget.value() || stdout.isExceeded() || stderr.isExceeded() { throw FileToolsError.outputTooLarge }
        if timedOut { throw FileToolsError.timedOut }
        guard process.terminationStatus == 0 else {
            let detail = stderr.string().trimmingCharacters(in: .whitespacesAndNewlines)
            throw FileToolsError.processFailed(String(detail.suffix(1_000)))
        }
        return SafeProcessOutput(stdout: stdout.string(), stderr: stderr.string())
    }

    private static func drain(_ fd: Int32, into buffer: CappedData) {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                buffer.append(Data(bytes[0..<count]))
                continue
            }
            if count < 0 && errno == EINTR { continue }
            return
        }
    }
}
