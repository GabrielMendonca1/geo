import Foundation

enum Remote {
    static let host = envValue("GARIME_REMOTE_HOST") ?? "garime"
    static let root = envValue("GARIME_REMOTE_ROOT") ?? "/mnt/garime/Vault/Captures"
    static let sshBin = envValue("GARIME_SSH_BIN") ?? "/usr/bin/ssh"
    static let scpBin = envValue("GARIME_SCP_BIN") ?? "/usr/bin/scp"
    static let identity = envValue("GARIME_SSH_KEY").map { expandPath($0).path }
        ?? homeDir.appendingPathComponent(".ssh/garime", isDirectory: false).path
    static let connectTimeout = envInt("GARIME_CONNECT_TIMEOUT", 10)
    static let commandTimeout = envDouble("GARIME_SSH_TIMEOUT", 120)
    static let batchLimit = envInt("GARIME_UPLOAD_BATCH", 20)
    static let interval = envDouble("GARIME_UPLOAD_INTERVAL", 45)
    static let backoffBase = envDouble("GARIME_UPLOAD_BACKOFF_BASE", 5)
    static let backoffMax = envDouble("GARIME_UPLOAD_BACKOFF_MAX", 300)

    static var options: [String] {
        var opts = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        if fm.isReadableFile(atPath: identity) {
            opts += ["-o", "IdentitiesOnly=yes", "-i", identity]
        }
        return opts
    }
}

func remoteConfigIsSafe() -> Bool {
    guard isSafeRemoteHost(Remote.host) else {
        logErr("refusing upload: unsafe remote host \(Remote.host)")
        return false
    }
    guard isSafeRemoteRoot(Remote.root) else {
        logErr("refusing upload: unsafe remote root \(Remote.root)")
        return false
    }
    return true
}

func uploadBatch(day: String, files: [URL]) -> Bool {
    let names = files.map { $0.lastPathComponent }
    guard isSafeDayFolder(day), names.allSatisfy(isSafeComponent) else {
        logErr("refusing upload batch: unsafe day or file name in \(day)")
        return false
    }

    let dayPath = "\(Remote.root)/\(day)"
    let incomingPath = "\(dayPath)/.incoming"

    let mkdir = runBounded(
        Remote.sshBin,
        Remote.options + [Remote.host, "mkdir -p '\(incomingPath)'"],
        timeout: Remote.commandTimeout
    )
    guard mkdir.ok else {
        logErr("upload: remote mkdir failed for \(day) (status \(mkdir.status), timedOut \(mkdir.timedOut))")
        return false
    }

    let copy = runBounded(
        Remote.scpBin,
        Remote.options + ["-p"] + files.map { $0.path } + ["\(Remote.host):\(incomingPath)/"],
        timeout: Remote.commandTimeout
    )
    guard copy.ok else {
        logErr("upload: scp failed for \(day) (status \(copy.status), timedOut \(copy.timedOut))")
        return false
    }

    let sources = names.map { "'\(incomingPath)/\($0)'" }.joined(separator: " ")
    let publish = runBounded(
        Remote.sshBin,
        Remote.options + [Remote.host, "mv -f -- \(sources) '\(dayPath)/'"],
        timeout: Remote.commandTimeout
    )
    guard publish.ok else {
        logErr("upload: remote publish failed for \(day) (status \(publish.status), timedOut \(publish.timedOut))")
        return false
    }

    for file in files {
        do {
            try fm.removeItem(at: file)
        } catch {
            logErr("upload: could not prune spooled \(file.lastPathComponent): \(error.localizedDescription)")
        }
    }
    logErr("upload: published \(files.count) file(s) to \(Remote.host):\(dayPath)")
    return true
}

struct UploadStatus {
    var lastPass = 0
    var lastSuccess = 0
    var failures = 0
    var spoolFiles = 0
    var spoolOldestAge = 0
}

func loadUploadStatus() -> UploadStatus? {
    guard let raw = try? String(contentsOf: uploadStatusURL, encoding: .utf8) else { return nil }
    var fields: [String: Int] = [:]
    for line in raw.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, let value = Int(parts[1]) else { continue }
        fields[String(parts[0])] = value
    }
    var status = UploadStatus()
    status.lastPass = fields["last_pass"] ?? 0
    status.lastSuccess = fields["last_success"] ?? 0
    status.failures = fields["failures"] ?? 0
    status.spoolFiles = fields["spool_files"] ?? 0
    status.spoolOldestAge = fields["spool_oldest_age"] ?? 0
    return status
}

func writeUploadStatus(_ status: UploadStatus) {
    let body = """
    last_pass=\(status.lastPass)
    last_success=\(status.lastSuccess)
    failures=\(status.failures)
    spool_files=\(status.spoolFiles)
    spool_oldest_age=\(status.spoolOldestAge)
    """
    try? fm.createDirectory(at: statusDir, withIntermediateDirectories: true)
    try? (body + "\n").write(to: uploadStatusURL, atomically: true, encoding: .utf8)
}

func recordUploadOutcome(ok: Bool) {
    let now = Int(Date().timeIntervalSince1970)
    var status = loadUploadStatus() ?? UploadStatus(lastPass: 0, lastSuccess: now, failures: 0)
    status.lastPass = now
    if ok {
        status.failures = 0
        status.lastSuccess = now
    } else {
        status.failures += 1
    }
    let stats = spoolStats()
    status.spoolFiles = stats.files
    status.spoolOldestAge = stats.oldestAge
    writeUploadStatus(status)
    if !ok {
        logErr("upload: \(status.failures) consecutive failure(s), \(stats.files) file(s) spooled, oldest \(stats.oldestAge)s, last success \(now - status.lastSuccess)s ago")
    }
}

func uploadPass() -> Bool {
    let ok = drainSpool()
    recordUploadOutcome(ok: ok)
    return ok
}

func drainSpool() -> Bool {
    guard remoteConfigIsSafe() else { return false }
    for day in spoolDays() {
        let files = spoolFiles(day: day)
        let strays = files.filter { !isMarkdown($0) }
        if !strays.isEmpty { adoptSpooledImages(files: strays) }
        let uploads = files.filter(isMarkdown)
        if uploads.isEmpty {
            pruneEmptyDay(day)
            continue
        }
        for batch in uploads.chunked(into: Remote.batchLimit) where !batch.isEmpty {
            guard uploadBatch(day: day, files: batch) else { return false }
        }
        pruneEmptyDay(day)
    }
    return true
}

func backoffDelay(failures: Int) -> TimeInterval {
    let exponent = Double(min(max(failures - 1, 0), 10))
    let delay = min(Remote.backoffMax, Remote.backoffBase * pow(2, exponent))
    return delay + Double.random(in: 0...(delay * 0.25))
}

func uploaderLoop() {
    logErr("uploader: target \(Remote.host):\(Remote.root), interval \(Int(Remote.interval))s")
    while true {
        beat(uploadHeartbeat)
        if uploadPass() {
            sleepBeating(Remote.interval, heartbeat: uploadHeartbeat)
        } else {
            let failures = loadUploadStatus()?.failures ?? 1
            let delay = backoffDelay(failures: failures)
            logErr("uploader: pass failed (\(failures) consecutive), retrying in \(Int(delay))s")
            sleepBeating(delay, heartbeat: uploadHeartbeat)
        }
    }
}
