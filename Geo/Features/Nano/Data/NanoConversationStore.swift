import Foundation
import SwiftUI
import AppKit
import os

private let storeLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "NanoConversationStore")

struct NanoConversationSummary: Identifiable, Sendable {
    let id: String   // suffix after "nano:" — e.g. "main", "uuid-..."
    let title: String
    let lastTs: Date
    let messageCount: Int
}

@MainActor
final class NanoConversationStore: ObservableObject {
    @Published private(set) var messages: [NanoMessage] = []
    @Published private(set) var isSending: Bool = false
    @Published var error: String?
    @Published private(set) var channelId: String
    @Published private(set) var conversations: [NanoConversationSummary] = []

    private let client: ClawIPCClient
    private var fullChannelId: String { "nano:\(channelId)" }

    init(client: ClawIPCClient = .shared, channelId: String = "main") {
        self.client = client
        self.channelId = channelId
    }

    func hydrate() async {
        do {
            let history = try await client.getHistory(channelId: fullChannelId, limit: 100)
            self.messages = history.map { entry in
                NanoMessage(
                    role: entry.role == "user" ? .user : .assistant,
                    text: entry.text,
                    isStreaming: false,
                    ts: Date(timeIntervalSince1970: TimeInterval(entry.ts) / 1000.0)
                )
            }
        } catch ClawIPCError.socketMissing {
            self.error = "geo-claw daemon isn't running. Start it with `launchctl load ~/Library/LaunchAgents/ai.geo.claw.plist` or check Settings."
        } catch {
            storeLogger.warning("hydrate failed: \(error.localizedDescription)")
        }
    }

    func reset() async {
        guard !isSending else { return }
        self.error = nil
        do {
            _ = try await client.resetSession(channelId: channelId)
            self.messages = []
            await refreshConversations()
        } catch {
            self.error = "Couldn't reset session: \(error.localizedDescription)"
            storeLogger.warning("reset failed: \(error.localizedDescription)")
        }
    }

    func switchTo(channelId newId: String) async {
        guard newId != channelId, !isSending else { return }
        self.channelId = newId
        self.messages = []
        self.error = nil
        await hydrate()
    }

    func newConversation() async {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        await switchTo(channelId: "c-\(suffix)")
    }

    func refreshConversations() async {
        do {
            let channels = try await client.listChannels(prefix: "nano:", limit: 50)
            self.conversations = channels.map { chan in
                let suffix = chan.channelId.replacingOccurrences(of: "nano:", with: "")
                return NanoConversationSummary(
                    id: suffix,
                    title: suffix == "main" ? "Main" : suffix,
                    lastTs: Date(timeIntervalSince1970: TimeInterval(chan.lastTs) / 1000.0),
                    messageCount: chan.msgCount
                )
            }
        } catch {
            storeLogger.debug("listChannels failed: \(error.localizedDescription)")
        }
    }

    func send(_ text: String, attachments: [NanoAttachment] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isSending else { return }
        self.error = nil
        isSending = true
        defer { isSending = false }

        let userText = trimmed.isEmpty && !attachments.isEmpty ? "(see attached)" : trimmed
        let userMessage = NanoMessage(role: .user, text: userText)
        let assistantMessage = NanoMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(userMessage)
        messages.append(assistantMessage)
        let assistantId = assistantMessage.id

        let ipcAttachments: [ClawIPCClient.IPCAttachment] = attachments.compactMap { attachment in
            switch attachment.kind {
            case .image(let image, let name):
                guard let data = imageData(image) else { return nil }
                return ClawIPCClient.IPCAttachment(
                    type: "image",
                    mediaType: "image/png",
                    base64: data.base64EncodedString(),
                    name: name
                )
            case .file(let url):
                guard let data = try? Data(contentsOf: url) else { return nil }
                let media = mediaType(for: url)
                return ClawIPCClient.IPCAttachment(
                    type: "file",
                    mediaType: media,
                    base64: data.base64EncodedString(),
                    name: url.lastPathComponent
                )
            }
        }

        do {
            let stream = try await client.runTurn(channelId: channelId, userText: userText, attachments: ipcAttachments)
            for try await event in stream {
                apply(event: event, toAssistant: assistantId)
            }
        } catch {
            apply(event: .failure(message: error.localizedDescription), toAssistant: assistantId)
            self.error = error.localizedDescription
        }
    }

    func cancel() async {
        guard isSending else { return }
        _ = try? await client.cancel(channelId: channelId)
    }

    private func imageData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func mediaType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "txt", "md": return "text/plain"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    private func apply(event: TurnEvent, toAssistant id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .text(let delta):
            messages[idx].text += delta
        case .toolUse(let toolId, let name, let input):
            messages[idx].toolCalls.append(NanoToolCall(id: toolId, name: name, input: input))
        case .toolResult(let toolId, let content, let isError):
            if let callIdx = messages[idx].toolCalls.firstIndex(where: { $0.id == toolId }) {
                messages[idx].toolCalls[callIdx].result = content
                messages[idx].toolCalls[callIdx].isError = isError
                messages[idx].toolCalls[callIdx].endedAt = Date()
            }
        case .done(let reply):
            messages[idx].isStreaming = false
            if let reply, messages[idx].text.isEmpty {
                messages[idx].text = reply
            }
        case .failure(let message):
            messages[idx].isStreaming = false
            if messages[idx].text.isEmpty {
                messages[idx].text = "⚠ \(message)"
            }
        }
    }
}
