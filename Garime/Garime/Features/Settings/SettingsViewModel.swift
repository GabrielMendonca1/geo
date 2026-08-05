import Foundation
import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance.preference"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "sistema"
        case .light: return "claro"
        case .dark: return "escuro"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var baseURL: String
    @Published var token: String
    @Published var termToken: String
    @Published private(set) var isTesting = false
    @Published private(set) var testResult: String?
    @Published private(set) var urlError: String?

    let client: any BridgeAPI

    init(client: any BridgeAPI = BridgeClient.shared) {
        self.client = client
        baseURL = BridgeConfig.baseURLString
        token = BridgeConfig.token
        termToken = BridgeConfig.termToken
    }

    var activeBaseURL: String {
        BridgeConfig.baseURLString
    }

    var defaultTerminalOrigin: String {
        let raw = UserDefaults.standard.string(forKey: "terminal.sessions") ?? "vm:mobile"
        let first = raw.split(separator: ",").first.map(String.init) ?? "vm:mobile"
        let origin = first.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "vm"
        return origin == "mac" ? "mac" : "vm"
    }

    var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        guard let build, !build.isEmpty, build != short else { return short }
        return "\(short) (\(build))"
    }

    @discardableResult
    func save() -> Bool {
        BridgeConfig.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        BridgeConfig.termToken = termToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BridgeConfig.isAllowedBaseURL(trimmedURL) else {
            urlError = "URL must be https, or http to a tailnet IP (100.64.0.0/10)"
            return false
        }
        BridgeConfig.baseURLString = trimmedURL
        urlError = nil
        return true
    }

    func testConnection() async {
        save()
        isTesting = true
        defer { isTesting = false }
        do {
            try await client.health()
            testResult = "Connected"
        } catch {
            testResult = error.localizedDescription
        }
    }
}
