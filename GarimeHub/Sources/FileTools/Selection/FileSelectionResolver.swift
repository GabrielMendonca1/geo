import Foundation

final class FileSelectionResolver {
    typealias Completion = (FileSelectionResolution) -> Void

    private final class Delivery {
        private let lock = NSLock()
        private var delivered = false
        private let queue: DispatchQueue
        private let completion: Completion

        init(queue: DispatchQueue, completion: @escaping Completion) {
            self.queue = queue
            self.completion = completion
        }

        func deliver(_ resolution: FileSelectionResolution) {
            lock.lock()
            let first = !delivered
            delivered = true
            lock.unlock()
            guard first else { return }
            queue.async { self.completion(resolution) }
        }
    }

    private let frontmost: FrontmostApplicationProviding
    private let finder: FileSelectionProviding
    private let accessibility: FileSelectionProviding
    private let policy: FileSelectionURLPolicy
    private let timeout: Double
    private let workQueue: DispatchQueue
    private let watchdogQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var activeRequests = 0
    private let maximumCallers: Int

    init(
        frontmost: FrontmostApplicationProviding,
        finder: FileSelectionProviding,
        accessibility: FileSelectionProviding,
        policy: FileSelectionURLPolicy = FileSelectionURLPolicy(),
        maximumCallers: Int = 1,
        timeout: Double = 4,
        workQueue: DispatchQueue = DispatchQueue(label: "ai.garime.hub.file-selection"),
        watchdogQueue: DispatchQueue = DispatchQueue(label: "ai.garime.hub.file-selection.watchdog"),
        callbackQueue: DispatchQueue = .main
    ) {
        self.frontmost = frontmost
        self.finder = finder
        self.accessibility = accessibility
        self.policy = policy
        self.maximumCallers = max(1, maximumCallers)
        self.timeout = max(0.05, timeout)
        self.workQueue = workQueue
        self.watchdogQueue = watchdogQueue
        self.callbackQueue = callbackQueue
    }

    @discardableResult
    func resolve(_ completion: @escaping Completion) -> UUID {
        let requestID = UUID()
        let delivery = Delivery(queue: callbackQueue, completion: completion)
        let source = frontmost.frontmostApplication()
        guard let source else {
            delivery.deliver(.failed(requestID: requestID, source: nil, failure: .noFrontmostApplication))
            return requestID
        }
        lock.lock()
        let admitted = activeRequests < maximumCallers
        if admitted { activeRequests += 1 }
        lock.unlock()
        guard admitted else {
            delivery.deliver(.failed(requestID: requestID, source: source, failure: .busy))
            return requestID
        }
        let provider = source.bundleIdentifier == "com.apple.finder" ? finder : accessibility
        watchdogQueue.asyncAfter(deadline: .now() + timeout) {
            delivery.deliver(.failed(requestID: requestID, source: source, failure: .timeout))
        }
        workQueue.async { [self] in
            let resolution = run(requestID: requestID, source: source, provider: provider)
            lock.lock()
            activeRequests -= 1
            lock.unlock()
            delivery.deliver(resolution)
        }
        return requestID
    }

    private func run(
        requestID: UUID,
        source: FileSelectionSource,
        provider: FileSelectionProviding
    ) -> FileSelectionResolution {
        do {
            let raw = try provider.selection(for: source)
            guard frontmost.frontmostApplication() == source else {
                throw FileSelectionFailure.sourceChanged
            }
            let selected = try policy.validate(raw.selectedURLs)
            let selectedPaths = Set(selected.map(\.path))
            var document: URL?
            if let rawDocument = raw.documentURL, let validated = try? policy.validate(rawDocument) {
                document = selectedPaths.contains(validated.path) ? nil : validated
            }
            if selected.isEmpty && document == nil {
                throw raw.selectionAvailability == .unsupported
                    ? FileSelectionFailure.unsupported
                    : FileSelectionFailure.noSelection
            }
            var candidates = selected.map { FileSelectionCandidate(kind: .selection, url: $0) }
            if let document {
                candidates.append(FileSelectionCandidate(kind: .document, url: document))
            }
            guard frontmost.frontmostApplication() == source else {
                throw FileSelectionFailure.sourceChanged
            }
            return FileSelectionResolution(
                requestID: requestID,
                source: source,
                candidates: candidates,
                selectionAvailability: raw.selectionAvailability,
                failure: nil
            )
        } catch let failure as FileSelectionFailure {
            return .failed(requestID: requestID, source: source, failure: failure)
        } catch {
            return .failed(requestID: requestID, source: source, failure: .providerError)
        }
    }
}
