import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "InlineImageLoader")

enum InlineImageLoaderError: LocalizedError {
    case unsupportedScheme(String)
    case missingFile(URL)
    case invalidResponse
    case decodeFailed
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            return "Unsupported image URL scheme: \(scheme)"
        case .missingFile:
            return "Image file not found for this block"
        case .invalidResponse:
            return "Invalid image response"
        case .decodeFailed:
            return "Failed to decode image"
        case .network(let error):
            return error.localizedDescription
        }
    }
}

final class InlineImageLoader {
    typealias Completion = (Result<NSImage, InlineImageLoaderError>) -> Void

    static let shared = InlineImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let stateQueue = DispatchQueue(label: "com.geo.inline-image-loader.state", attributes: .concurrent)
    private let workQueue = DispatchQueue(label: "com.geo.inline-image-loader.work", qos: .userInitiated)
    private var inFlight: [String: [Completion]] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    func loadImage(from url: URL, completion: @escaping Completion) {
        let key = cacheKey(for: url)

        if let cached = cache.object(forKey: key as NSString) {
            DispatchQueue.main.async {
                completion(.success(cached))
            }
            return
        }

        guard registerCallback(key, completion) else { return }

        if url.isFileURL {
            workQueue.async {
                let result = self.loadLocalImage(url)
                self.complete(result: result, for: key, url: url)
            }
            return
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            let scheme = url.scheme?.lowercased() ?? "unknown"
            complete(result: .failure(.unsupportedScheme(scheme)), for: key, url: url)
            return
        }

        let task = session.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }

            if let error {
                self.complete(result: .failure(.network(error)), for: key, url: url)
                return
            }

            guard let data, !data.isEmpty else {
                self.complete(result: .failure(.invalidResponse), for: key, url: url)
                return
            }

            guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else {
                self.complete(result: .failure(.decodeFailed), for: key, url: url)
                return
            }

            self.complete(result: .success(image), for: key, url: url)
        }
        task.resume()
    }

    private func loadLocalImage(_ url: URL) -> Result<NSImage, InlineImageLoaderError> {
        let normalizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
            return .failure(.missingFile(normalizedURL))
        }

        guard let image = NSImage(contentsOf: normalizedURL), image.isValid, image.size.width > 0, image.size.height > 0 else {
            return .failure(.decodeFailed)
        }

        return .success(image)
    }

    private func registerCallback(_ key: String, _ callback: @escaping Completion) -> Bool {
        var shouldStartLoad = false
        stateQueue.sync(flags: .barrier) {
            if var callbacks = inFlight[key] {
                callbacks.append(callback)
                inFlight[key] = callbacks
            } else {
                inFlight[key] = [callback]
                shouldStartLoad = true
            }
        }
        return shouldStartLoad
    }

    private func drainCallbacks(_ key: String) -> [Completion] {
        var callbacks: [Completion] = []
        stateQueue.sync(flags: .barrier) {
            callbacks = inFlight.removeValue(forKey: key) ?? []
        }
        return callbacks
    }

    private func complete(result: Result<NSImage, InlineImageLoaderError>, for key: String, url: URL) {
        if case .success(let image) = result {
            let cost = image.representations.reduce(0) { total, rep in
                total + rep.pixelsWide * rep.pixelsHigh * 4
            }
            cache.setObject(image, forKey: key as NSString, cost: max(cost, 1))
        }

        if case .failure(let error) = result {
            logFailure(url: url, error: error)
        }

        let callbacks = drainCallbacks(key)

        guard !callbacks.isEmpty else { return }

        DispatchQueue.main.async {
            callbacks.forEach { $0(result) }
        }
    }

    private func cacheKey(for url: URL) -> String {
        if url.isFileURL {
            return "file://\(url.standardizedFileURL.path)"
        }
        return url.absoluteString
    }

    private func logFailure(url: URL, error: InlineImageLoaderError) {
        logger.debug("Failed to load \(url.absoluteString) -> \(error.localizedDescription)")
    }
}
