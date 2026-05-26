import Foundation

enum NanoTransportFactory {
    @MainActor
    static func makeDefault() -> any NanoTransport {
        let base = URL(string: "http://127.0.0.1:8642")!
        let key = HermesEnv.shared.apiServerKey ?? ""
        return HermesHTTPTransport(baseURL: base, apiKey: key)
    }
}
