import Foundation

struct OmniEndpoint: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var useTLS: Bool
    var tokenKeychainRef: String
    var repos: [String]
    var safeMode: Bool

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        useTLS: Bool = true,
        tokenKeychainRef: String,
        repos: [String] = [],
        safeMode: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.tokenKeychainRef = tokenKeychainRef
        self.repos = repos
        self.safeMode = safeMode
    }
}
