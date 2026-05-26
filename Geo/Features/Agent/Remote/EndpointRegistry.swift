import Foundation
import os
import Security

enum EndpointRegistryError: Error {
    case keychainFailure(Error)
    case persistenceFailure(Error)
    case notFound
    case alreadyExists(name: String)
}

@MainActor
final class EndpointRegistry: ObservableObject {
    @Published private(set) var endpoints: [OmniEndpoint] = []

    private static let keychainService = "ai.geo.endpoints"

    private let storeURL: URL
    private weak var authGuard: MCPAuthGuard?
    private let logger = Logger(subsystem: "ai.geo", category: "EndpointRegistry")

    init(authGuard: MCPAuthGuard? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.storeURL = base.appendingPathComponent("Geo/endpoints.json")
        self.authGuard = authGuard
        ensureParentDirectory()
        load()
    }

    func add(_ endpoint: OmniEndpoint, token: String) throws {
        if endpoints.contains(where: { $0.name.caseInsensitiveCompare(endpoint.name) == .orderedSame }) {
            throw EndpointRegistryError.alreadyExists(name: endpoint.name)
        }
        let ref = "mcp_endpoint_token_\(endpoint.id.uuidString)"
        var copy = endpoint
        copy.tokenKeychainRef = ref
        do {
            try KeychainHelper.set(token, for: ref, service: Self.keychainService)
        } catch {
            logger.error("Keychain write failed for \(ref, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw EndpointRegistryError.keychainFailure(error)
        }
        endpoints.append(copy)
        do {
            try save()
        } catch {
            try? KeychainHelper.delete(ref, service: Self.keychainService)
            endpoints.removeAll { $0.id == copy.id }
            throw EndpointRegistryError.persistenceFailure(error)
        }
        syncAuthGuard()
    }

    func update(_ endpoint: OmniEndpoint, newToken: String? = nil) throws {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else {
            throw EndpointRegistryError.notFound
        }
        if endpoints.contains(where: { $0.id != endpoint.id && $0.name.caseInsensitiveCompare(endpoint.name) == .orderedSame }) {
            throw EndpointRegistryError.alreadyExists(name: endpoint.name)
        }
        var copy = endpoint
        if copy.tokenKeychainRef.isEmpty {
            copy.tokenKeychainRef = "mcp_endpoint_token_\(copy.id.uuidString)"
        }
        if let newToken {
            do {
                try KeychainHelper.set(newToken, for: copy.tokenKeychainRef, service: Self.keychainService)
            } catch {
                logger.error("Keychain update failed: \(error.localizedDescription, privacy: .public)")
                throw EndpointRegistryError.keychainFailure(error)
            }
        }
        endpoints[index] = copy
        do {
            try save()
        } catch {
            throw EndpointRegistryError.persistenceFailure(error)
        }
        syncAuthGuard()
    }

    func remove(id: UUID) throws {
        guard let index = endpoints.firstIndex(where: { $0.id == id }) else {
            throw EndpointRegistryError.notFound
        }
        let removed = endpoints.remove(at: index)
        do {
            try KeychainHelper.delete(removed.tokenKeychainRef, service: Self.keychainService)
        } catch {
            logger.error("Keychain delete failed for \(removed.tokenKeychainRef, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        do {
            try save()
        } catch {
            endpoints.insert(removed, at: index)
            throw EndpointRegistryError.persistenceFailure(error)
        }
        syncAuthGuard()
    }

    func token(for endpoint: OmniEndpoint) -> String? {
        KeychainHelper.get(endpoint.tokenKeychainRef, service: Self.keychainService)
    }

    func regenerateToken(for id: UUID) throws -> String {
        guard let index = endpoints.firstIndex(where: { $0.id == id }) else {
            throw EndpointRegistryError.notFound
        }
        var entry = endpoints[index]
        if entry.tokenKeychainRef.isEmpty {
            entry.tokenKeychainRef = "mcp_endpoint_token_\(entry.id.uuidString)"
            endpoints[index] = entry
        }
        let newToken = generateWorkerToken()
        do {
            try KeychainHelper.set(newToken, for: entry.tokenKeychainRef, service: Self.keychainService)
        } catch {
            logger.error("Keychain regenerate failed: \(error.localizedDescription, privacy: .public)")
            throw EndpointRegistryError.keychainFailure(error)
        }
        do {
            try save()
        } catch {
            throw EndpointRegistryError.persistenceFailure(error)
        }
        syncAuthGuard()
        return newToken
    }

    private func ensureParentDirectory() {
        let parent = storeURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create parent dir: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            endpoints = []
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoded = try JSONDecoder().decode([OmniEndpoint].self, from: data)
            endpoints = decoded
        } catch {
            logger.error("Failed to decode endpoints.json: \(error.localizedDescription, privacy: .public)")
            endpoints = []
        }
    }

    private func save() throws {
        ensureParentDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(endpoints)
        try data.write(to: storeURL, options: .atomic)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        } catch {
            logger.error("Failed to chmod endpoints.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func generateWorkerToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes).base64EncodedString()
        }
        var fallback = [UInt8](repeating: 0, count: 32)
        for i in 0..<fallback.count {
            fallback[i] = UInt8.random(in: 0...255)
        }
        return Data(fallback).base64EncodedString()
    }

    private func syncAuthGuard() {
        guard let authGuard else {
            if !endpoints.isEmpty {
                logger.error("syncAuthGuard skipped: authGuard is nil with \(self.endpoints.count, privacy: .public) endpoint(s) registered — worker tokens not propagated")
            }
            return
        }
        var liveDigests: Set<String> = []
        var liveTokensByDigest: [String: String] = [:]
        for endpoint in endpoints {
            guard let token = KeychainHelper.get(endpoint.tokenKeychainRef, service: Self.keychainService) else { continue }
            authGuard.register(token: token, endpointId: endpoint.id, endpointName: endpoint.name)
            let digest = MCPAuthGuard.digest(of: token)
            liveDigests.insert(digest)
            liveTokensByDigest[digest] = token
        }
        let snapshot = authGuard.snapshot()
        for (digest, _) in snapshot where !liveDigests.contains(digest) {
            authGuard.revokeDigest(digest)
        }
        _ = liveTokensByDigest
    }
}
