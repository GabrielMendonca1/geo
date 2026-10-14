import Darwin
import Foundation

struct FileSelectionURLPolicy {
    let maximumCount: Int
    let maximumPathLength: Int
    let rejectSymbolicLinks: Bool

    init(maximumCount: Int = 128, maximumPathLength: Int = 1024, rejectSymbolicLinks: Bool = true) {
        self.maximumCount = max(1, maximumCount)
        self.maximumPathLength = max(1, maximumPathLength)
        self.rejectSymbolicLinks = rejectSymbolicLinks
    }

    func validate(_ rawURLs: [URL]) throws -> [URL] {
        guard rawURLs.count <= maximumCount else { throw FileSelectionFailure.tooManyItems }
        var result: [URL] = []
        var seen: Set<String> = []
        for rawURL in rawURLs {
            let url = try validate(rawURL)
            if seen.insert(url.path).inserted { result.append(url) }
        }
        return result
    }

    func validate(_ rawURL: URL) throws -> URL {
        guard rawURL.scheme?.lowercased() == "file" else { throw FileSelectionFailure.invalidURL }
        let host = rawURL.host?.lowercased() ?? ""
        guard host.isEmpty || host == "localhost" else { throw FileSelectionFailure.invalidURL }
        guard rawURL.baseURL == nil else { throw FileSelectionFailure.invalidURL }
        let url = URL(fileURLWithPath: rawURL.path).standardized
        guard url.path.hasPrefix("/"), url.path != "/" else { throw FileSelectionFailure.invalidURL }
        guard url.path.utf8.count <= maximumPathLength else { throw FileSelectionFailure.invalidURL }
        guard !url.path.contains("\u{0}") else { throw FileSelectionFailure.invalidURL }
        if rejectSymbolicLinks { try rejectLinks(in: url.path) }
        return url
    }

    private func rejectLinks(in path: String) throws {
        let components = URL(fileURLWithPath: path).standardized.pathComponents
        var current = ""
        for component in components {
            if component == "/" {
                current = "/"
                continue
            }
            current = (current as NSString).appendingPathComponent(component)
            var info = stat()
            guard lstat(current, &info) == 0 else { throw FileSelectionFailure.invalidURL }
            if (info.st_mode & S_IFMT) == S_IFLNK { throw FileSelectionFailure.symbolicLink }
        }
    }
}
