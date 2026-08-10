import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

func ensureDirectories() {
    for dir in [baseDir, archiveDir, statusDir, registryURL.deletingLastPathComponent()] {
        if isForbiddenPath(dir) {
            logErr("FATAL: \(dir.path) is inside a forbidden vault root; refusing to run")
            exit(78)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    warnLegacySpool()
}

func printUsage() {
    let text = """
    usage: garimecapture [command]

      (no command)         run the daemon: watch screenshots, OCR to the clipboard, archive, purge
      retention-once       purge archived images past the retention window and exit
      capture-once PATH..  run the full capture pipeline on the given images and exit
      clipboard-show       print what is on the capture pasteboard right now
      ocr-classify D C     print how a Vision error (domain D, code C) is classified
      paths                print resolved paths
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func runDaemon() {
    beat(captureHeartbeat)
    beat(retentionHeartbeat)
    logErr("garimecapture starting (archive \(archiveDir.path), no network, OCR text never touches disk)")

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
case "retention-once":
    ensureDirectories()
    exit(retentionPass() ? 0 : 1)
case "capture-once":
    ensureDirectories()
    exit(captureOnce(paths: Array(arguments.dropFirst())) ? 0 : 1)
case "clipboard-show":
    dumpClipboard()
    exit(0)
case "ocr-classify":
    let rest = Array(arguments.dropFirst())
    guard rest.count >= 2, let code = Int(rest[1]) else {
        printUsage()
        exit(64)
    }
    switch classifyOCRFailure(domain: rest[0], code: code, description: rest.count > 2 ? rest[2] : "probe") {
    case .text: print("text")
    case .refused: print("refused")
    case .failed: print("failed")
    case .timedOut: print("timedOut")
    }
    exit(0)
case "paths":
    ensureDirectories()
    print("base=\(baseDir.path)")
    print("archive=\(archiveDir.path)")
    print("status=\(statusDir.path)")
    print("registry=\(registryURL.path)")
    exit(0)
default:
    printUsage()
    exit(64)
}
