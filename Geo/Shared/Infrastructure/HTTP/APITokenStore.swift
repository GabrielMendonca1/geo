import Foundation
import Security
import CryptoKit
import os

enum TokenScope: String, Codable, Sendable, CaseIterable {
    case read
    case readWrite = "read+write"
    case readWriteDestructive = "read+write+destructive"

    var rank: Int {
        switch self {
        case .read: return 0
        case .readWrite: return 1
        case .readWriteDestructive: return 2
        }
    }

    func allows(_ required: TokenScope) -> Bool {
        return rank >= required.rank
    }
}

struct ValidatedToken: Sendable {
    let callerId: String
    let scope: TokenScope
    let expiresAt: Date?
}

struct TokenSummary: Sendable, Codable {
    let callerId: String
    let scope: TokenScope
    let lastUsedAt: Date?
    let expiresAt: Date?
    let createdAt: Date
}

private struct TokenAttributes: Codable {
    let callerId: String
    let scope: TokenScope
    let expiresAt: Date?
    let createdAt: Date
}

final class APITokenStore: @unchecked Sendable {
    static let shared = APITokenStore()

    static let service = "geo-api"
    static let bootstrapService = "geo-api-bootstrap"
    static let bootstrapRuntime = "hermes-runtime"
    static let bootstrapHook = "hermes-hook"
    private static let lastUsedDefaultsKey = "ai.geo.api.lastUsed"

    private let lastUsedLock = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])
    private var flushTimer: DispatchSourceTimer?
    private let flushQueue = DispatchQueue(label: "geo.http.tokens.flush")

    init() {
        loadLastUsedFromDisk()
        startFlushTimer()
    }

    deinit {
        flushTimer?.cancel()
    }

    static func digest(of token: String) -> String {
        let hash = SHA256.hash(data: Data(token.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func add(callerId: String, scope: TokenScope, expiresAt: Date?) -> String {
        let raw = Self.generateRaw()
        let digest = Self.digest(of: raw)
        let attrs = TokenAttributes(callerId: callerId, scope: scope, expiresAt: expiresAt, createdAt: Date())
        _ = revoke(callerId: callerId)
        storeHash(callerId: callerId, digest: digest, attrs: attrs)
        return raw
    }

    func addBootstrap(callerId: String, scope: TokenScope) -> String {
        let raw = add(callerId: callerId, scope: scope, expiresAt: nil)
        storeBootstrapRaw(callerId: callerId, raw: raw)
        return raw
    }

    func validate(rawToken: String) -> ValidatedToken? {
        let digest = Self.digest(of: rawToken)
        guard let (attrs, callerId) = lookupByDigest(digest) else { return nil }
        if let exp = attrs.expiresAt, exp <= Date() { return nil }
        lastUsedLock.withLock { $0[callerId] = Date() }
        return ValidatedToken(callerId: callerId, scope: attrs.scope, expiresAt: attrs.expiresAt)
    }

    func list() -> [TokenSummary] {
        let entries = listAllAttributes()
        let lastUsed = lastUsedLock.withLock { $0 }
        return entries.map { entry in
            TokenSummary(
                callerId: entry.callerId,
                scope: entry.scope,
                lastUsedAt: lastUsed[entry.callerId],
                expiresAt: entry.expiresAt,
                createdAt: entry.createdAt
            )
        }.sorted { $0.callerId < $1.callerId }
    }

    @discardableResult
    func revoke(callerId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: callerId,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }

    func readBootstrapRaw(callerId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.bootstrapService,
            kSecAttrAccount as String: callerId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    func ensureBootstrapTokens() {
        let runtimeRaw = readBootstrapRaw(callerId: Self.bootstrapRuntime)
        if runtimeRaw == nil || validate(rawToken: runtimeRaw!) == nil {
            _ = addBootstrap(callerId: Self.bootstrapRuntime, scope: .readWriteDestructive)
        }
        let hookRaw = readBootstrapRaw(callerId: Self.bootstrapHook)
        if hookRaw == nil || validate(rawToken: hookRaw!) == nil {
            _ = addBootstrap(callerId: Self.bootstrapHook, scope: .read)
        }
    }

    private func storeHash(callerId: String, digest: String, attrs: TokenAttributes) {
        guard let attrData = try? JSONEncoder().encode(attrs) else { return }
        let digestData = Data(digest.utf8)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: callerId,
            kSecValueData as String: digestData,
            kSecAttrGeneric as String: attrData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        _ = SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func storeBootstrapRaw(callerId: String, raw: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.bootstrapService,
            kSecAttrAccount as String: callerId,
        ]
        _ = SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.bootstrapService,
            kSecAttrAccount as String: callerId,
            kSecValueData as String: Data(raw.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        _ = SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func lookupByDigest(_ digest: String) -> (TokenAttributes, String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return nil }
        let target = Data(digest.utf8)
        for item in items {
            guard let callerId = item[kSecAttrAccount as String] as? String,
                  let data = readDigestData(callerId: callerId),
                  Self.constantTimeEquals(data, target) else { continue }
            guard let attrData = item[kSecAttrGeneric as String] as? Data,
                  let attrs = try? JSONDecoder().decode(TokenAttributes.self, from: attrData) else {
                continue
            }
            return (attrs, callerId)
        }
        return nil
    }

    private func readDigestData(callerId: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: callerId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    private func listAllAttributes() -> [TokenAttributes] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        var out: [TokenAttributes] = []
        for item in items {
            guard let attrData = item[kSecAttrGeneric as String] as? Data,
                  let attrs = try? JSONDecoder().decode(TokenAttributes.self, from: attrData) else {
                continue
            }
            out.append(attrs)
        }
        return out
    }

    private static func generateRaw() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private func loadLastUsedFromDisk() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.lastUsedDefaultsKey) as? [String: TimeInterval] else { return }
        let mapped = raw.mapValues { Date(timeIntervalSince1970: $0) }
        lastUsedLock.withLock { $0 = mapped }
    }

    private func startFlushTimer() {
        let t = DispatchSource.makeTimerSource(queue: flushQueue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.flushLastUsedToDisk() }
        t.resume()
        flushTimer = t
    }

    private func flushLastUsedToDisk() {
        let snapshot = lastUsedLock.withLock { $0 }
        let raw = snapshot.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: Self.lastUsedDefaultsKey)
    }
}
