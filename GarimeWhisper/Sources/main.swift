import AppKit
import Darwin

private var instanceLockDescriptor: Int32 = -1

private func claimSingleInstance() -> Bool {
    try? FileManager.default.createDirectory(
        atPath: Config.workDirectory,
        withIntermediateDirectories: true
    )
    let path = Config.workDirectory + "/instance.lock"
    let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0 else { return true }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor)
        return false
    }
    instanceLockDescriptor = descriptor
    return true
}

guard claimSingleInstance() else {
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()
