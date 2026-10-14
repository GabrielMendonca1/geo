import CoreServices
import Foundation

final class PathWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: CFTimeInterval
    private let onChange: () -> Void
    private let accepts: (String) -> Bool

    init(
        paths: [String],
        latency: CFTimeInterval = 0.5,
        accepts: @escaping (String) -> Bool = { _ in true },
        onChange: @escaping () -> Void
    ) {
        self.paths = paths
        self.latency = latency
        self.accepts = accepts
        self.onChange = onChange
    }

    fileprivate func deliver(_ changed: [String]) {
        guard changed.isEmpty || changed.contains(where: accepts) else { return }
        onChange()
    }

    deinit {
        stop()
    }

    var isRunning: Bool { stream != nil }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let changed = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []
            Unmanaged<PathWatcher>.fromOpaque(info).takeUnretainedValue().deliver(changed)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
