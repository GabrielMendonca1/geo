import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

func ensureDirectories() {
    for dir in [baseDir, spoolDir, archiveDir, statusDir, registryURL.deletingLastPathComponent()] {
        if isForbiddenPath(dir) {
            logErr("FATAL: \(dir.path) is inside a forbidden vault root; refusing to run")
            exit(78)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

func printUsage() {
    let text = """
    usage: garimecapture [command]

      (no command)      run the daemon: watch screenshots, OCR, spool, upload, purge
      upload-once       drain the spool once and exit (0 = drained, 1 = failed)
      retention-once    purge archived images past the retention window and exit
      spool-add PATH..  ingest files into the spool without OCR, then remove them
      paths             print resolved paths and remote target
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func runDaemon() {
    beat(captureHeartbeat)
    beat(uploadHeartbeat)
    beat(retentionHeartbeat)
    logErr("garimecapture starting (spool \(spoolDir.path) -> \(Remote.host):\(Remote.root), archive \(archiveDir.path))")

    let uploader = Thread { uploaderLoop() }
    uploader.name = "ai.garime.capture.upload"
    uploader.stackSize = 512 * 1024
    uploader.start()

    let reaper = Thread { retentionLoop() }
    reaper.name = "ai.garime.capture.retention"
    reaper.stackSize = 512 * 1024
    reaper.start()

    warmUpOCR()
    var watchedDir = screenshotsDirectory()
    logErr("watching \(watchedDir.path)")

    while true {
        let dir = screenshotsDirectory()
        if dir != watchedDir {
            logErr("watched directory changed: \(watchedDir.path) -> \(dir.path)")
            watchedDir = dir
        }
        scan(directory: dir)
        beat(captureHeartbeat)
        Thread.sleep(forTimeInterval: pollInterval)
    }
}

switch arguments.first {
case nil:
    ensureDirectories()
    runDaemon()
case "upload-once":
    ensureDirectories()
    exit(uploadPass() ? 0 : 1)
case "retention-once":
    ensureDirectories()
    exit(retentionPass() ? 0 : 1)
case "spool-add":
    ensureDirectories()
    exit(spoolAdd(paths: Array(arguments.dropFirst())) ? 0 : 1)
case "paths":
    ensureDirectories()
    print("base=\(baseDir.path)")
    print("spool=\(spoolDir.path)")
    print("archive=\(archiveDir.path)")
    print("status=\(statusDir.path)")
    print("registry=\(registryURL.path)")
    print("remote=\(Remote.host):\(Remote.root)")
    print("ssh=\(Remote.sshBin)")
    print("scp=\(Remote.scpBin)")
    exit(0)
default:
    printUsage()
    exit(64)
}
