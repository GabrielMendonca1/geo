import Foundation
import CoreServices

final class FileWatcherService {
    private let url: URL
    private let latency: CFTimeInterval
    private var stream: FSEventStreamRef?
    private var retainedSelf: Unmanaged<FileWatcherService>?
    var onChange: (([URL]) -> Void)?

    init(url: URL, latency: CFTimeInterval = 0.15) {
        self.url = url
        self.latency = latency
    }

    func start() {
        guard stream == nil else { return }
        let retained = Unmanaged.passRetained(self)
        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [url.path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            FileWatcherService.callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            retained.release()
            return
        }
        self.retainedSelf = retained
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        retainedSelf?.release()
        retainedSelf = nil
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func handlePaths(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        DispatchQueue.main.async {
            self.onChange?(urls)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcherService>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        watcher.handlePaths(paths)
    }
}
