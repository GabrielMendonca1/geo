import Foundation

struct NanoTransportAttachment: Sendable {
    let type: String
    let mediaType: String
    let base64: String
    let name: String?

    init(type: String, mediaType: String, base64: String, name: String? = nil) {
        self.type = type
        self.mediaType = mediaType
        self.base64 = base64
        self.name = name
    }
}

struct NanoChannelInfo: Sendable, Identifiable {
    var id: String { channelID }
    let channelID: String
    let lastTs: Int64
    let msgCount: Int
}

struct NanoHistoryMessage: Sendable, Identifiable {
    let id: Int64
    let channelID: String
    let role: NanoMessageRole
    let text: String
    let ts: Int64
}

protocol NanoTransport: Actor {
    func runTurn(
        channelID: String,
        text: String,
        attachments: [NanoTransportAttachment]
    ) async throws -> AsyncThrowingStream<TurnEvent, Error>

    func cancel(channelID: String) async throws

    func resetSession(channelID: String) async throws

    func getHistory(
        channelID: String,
        limit: Int,
        afterCursor: Int64?
    ) async throws -> [NanoHistoryMessage]

    func listChannels(prefix: String?) async throws -> [NanoChannelInfo]
}
