import Foundation

enum OpenFileRouter {
    enum Outcome: Equatable {
        case openExisting(blockId: String)
        case create(url: URL)
        case external(url: URL)
    }

    static let supportedExtensions: Set<String> = ["md", "markdown", "txt", "text"]

    static func resolve(
        urls: [URL],
        vaultDirectory: URL,
        existingByPath: [String: String]
    ) -> [Outcome] {
        let vaultPath = vaultDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let vaultPrefix = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"
        return urls.compactMap { raw in
            guard supportedExtensions.contains(raw.pathExtension.lowercased()) else { return nil }
            let url = raw.resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(vaultPrefix) else { return .external(url: url) }
            if let id = existingByPath[url.path] { return .openExisting(blockId: id) }
            return .create(url: url)
        }
    }
}
