import Foundation
import Security

enum BridgeConfig {
    static let defaultBaseURL = BridgeSecrets.baseURL
    private static let baseURLKey = "bridge.baseURL"
    private static let legacyBaseURL = "https://garime-bridge.tail091418.ts.net"
    private static let tokenAccount = "geobridge-token"
    private static let termTokenAccount = "geobridge-term-token"

    static var baseURLString: String {
        get {
            let raw = UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
            if raw == legacyBaseURL {
                UserDefaults.standard.set(defaultBaseURL, forKey: baseURLKey)
                return defaultBaseURL
            }
            return raw.isEmpty ? defaultBaseURL : raw
        }
        set {
            guard isAllowedBaseURL(newValue) else { return }
            UserDefaults.standard.set(newValue, forKey: baseURLKey)
        }
    }

    static func isAllowedBaseURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host else { return false }
        if url.scheme == "https" && host.hasSuffix(".ts.net") { return true }
        guard url.scheme == "http" else { return false }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    static var token: String? {
        get { KeychainStore.read(tokenAccount) }
        set { _ = setToken(newValue ?? "") }
    }

    static var termToken: String? {
        get { KeychainStore.read(termTokenAccount) }
        set { _ = setTermToken(newValue ?? "") }
    }

    @discardableResult
    static func setToken(_ value: String) -> Bool {
        KeychainStore.write(tokenAccount, value)
    }

    @discardableResult
    static func setTermToken(_ value: String) -> Bool {
        KeychainStore.write(termTokenAccount, value)
    }
}

enum KeychainStore {
    private static let service = "com.gabrielmendonca.garime.bridge"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ account: String, _ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let deleted = SecItemDelete(base as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return false }
        guard !value.isEmpty else { return true }
        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
