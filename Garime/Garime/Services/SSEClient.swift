import Foundation

struct SSEClient: Sendable {
    let client: any BridgeAPI
    let path: String
    let method: String
    let body: Data?
    let token: String?
    let timeoutInterval: TimeInterval

    init(
        client: any BridgeAPI,
        path: String,
        method: String = "GET",
        body: Data? = nil,
        token: String? = nil,
        timeoutInterval: TimeInterval = BridgeClient().streamTimeout
    ) {
        self.client = client
        self.path = path
        self.method = method
        self.body = body
        self.token = token
        self.timeoutInterval = timeoutInterval
    }

    func stream() -> AsyncThrowingStream<SSEMessage, Error> {
        client.stream(path, method: method, body: body, token: token)
    }
}
