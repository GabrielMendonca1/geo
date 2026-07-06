import Foundation
import Security

enum BridgeConfig {
    static let defaultBaseURL = BridgeSecrets.baseURL
    private static let baseURLKey = "bridge.baseURL"
    private static let tokenAccount = "geobridge-token"
    private static let termTokenAccount = "geobridge-term-token"

    static var baseURLString: String {
        get {
            let raw = UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
            return raw.isEmpty ? defaultBaseURL : raw
        }
        set {
            guard isAllowedBaseURL(newValue) else { return }
            UserDefaults.standard.set(newValue, forKey: baseURLKey)
        }
    }

    static func isAllowedBaseURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host else { return false }
        if url.scheme == "https" { return true }
        guard url.scheme == "http" else { return false }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    static var token: String {
        get { KeychainStore.read(tokenAccount) ?? BridgeSecrets.token }
        set { KeychainStore.write(tokenAccount, newValue) }
    }

    static var termToken: String {
        get { KeychainStore.read(termTokenAccount) ?? BridgeSecrets.termToken }
        set { KeychainStore.write(termTokenAccount, newValue) }
    }
}

enum KeychainStore {
    private static let service = "com.gabrielmendonca.geomobile.bridge"

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

    static func write(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
