import Foundation

final class HermesEnv: @unchecked Sendable {
    static let shared = HermesEnv()

    let apiServerKey: String?
    let apiServerEnabled: Bool

    init(envPath: String? = nil) {
        let path: String = envPath ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.hermes/.env"
        let entries = Self.load(path: path)
        self.apiServerKey = entries["API_SERVER_KEY"]
        if let enabledRaw = entries["API_SERVER_ENABLED"]?.lowercased() {
            self.apiServerEnabled = enabledRaw == "1" || enabledRaw == "true" || enabledRaw == "yes"
        } else {
            self.apiServerEnabled = false
        }
    }

    private static func load(path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }
}
