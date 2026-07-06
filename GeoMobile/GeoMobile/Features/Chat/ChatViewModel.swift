import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var text: String
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isStreaming = false

    let sessionID: String
    let client: BridgeClient
    var onAssistantCompleted: ((String) -> Void)?
    var onAssistantDelta: ((String) -> Void)?
    var onThinking: (() -> Void)?
    var onStreamEnded: (() -> Void)?
    var onStreamFailed: (() -> Void)?

    private var streamTask: Task<Void, Never>?

    init(client: BridgeClient = .shared) {
        self.client = client
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "chat.sessionID"), !stored.isEmpty {
            sessionID = stored
        } else {
            sessionID = "iphone-main"
            defaults.set(sessionID, forKey: "chat.sessionID")
        }
    }

    @discardableResult
    func send() async -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return false }
        draft = ""
        messages.append(ChatMessage(role: "user", text: text))
        isStreaming = true
        onThinking?()
        let task = Task { await self.runStream(text) }
        streamTask = task
        await task.value
        streamTask = nil
        isStreaming = false
        return true
    }

    func cancelStreaming() {
        streamTask?.cancel()
    }

    private func runStream(_ text: String) async {
        guard let body = try? JSONSerialization.data(withJSONObject: ["session_id": sessionID, "message": text]) else {
            appendSystem("não consegui montar a mensagem")
            onStreamFailed?()
            return
        }
        var assistantIndex: Int?
        var streamCompleted = false
        var streamFailed = false
        do {
            for try await event in client.stream("/chat/stream", method: "POST", body: body) {
                if Task.isCancelled { return }
                switch event.event {
                case "assistant.delta":
                    guard let delta = Self.field("delta", in: event.data), !delta.isEmpty else { break }
                    if let index = assistantIndex {
                        messages[index].text += delta
                    } else {
                        messages.append(ChatMessage(role: "assistant", text: delta))
                        assistantIndex = messages.count - 1
                    }
                    onAssistantDelta?(delta)
                case "run.started", "message.started", "tool.progress":
                    onThinking?()
                case "assistant.completed":
                    let content = Self.field("content", in: event.data) ?? ""
                    if let index = assistantIndex {
                        if !content.isEmpty { messages[index].text = content }
                        onAssistantCompleted?(messages[index].text)
                    } else if !content.isEmpty {
                        messages.append(ChatMessage(role: "assistant", text: content))
                        onAssistantCompleted?(content)
                    }
                    assistantIndex = nil
                    streamCompleted = true
                case "error":
                    appendSystem(Self.field("message", in: event.data) ?? "hermes retornou um erro")
                    streamFailed = true
                case "done":
                    if streamFailed { onStreamFailed?() }
                    else if !streamCompleted { onStreamEnded?() }
                    return
                default:
                    break
                }
            }
        } catch {
            if Task.isCancelled { return }
            appendSystem(Self.systemText(for: error))
            onStreamFailed?()
        }
    }

    func appendSystem(_ text: String) {
        messages.append(ChatMessage(role: "system", text: text))
    }

    private static func field(_ key: String, in data: String) -> String? {
        guard let raw = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        return object[key] as? String
    }

    private static func systemText(for error: Error) -> String {
        switch error {
        case BridgeError.unauthorized:
            return "token da bridge inválido — confira em Settings"
        case BridgeError.server(_, "hermes_unreachable"):
            return "hermes fora do ar"
        case let BridgeError.server(status, code):
            return code.isEmpty ? "bridge retornou erro \(status)" : "bridge: \(code) (\(status))"
        case BridgeError.unreachable:
            return "bridge fora de alcance — confira Tailscale e a URL em Settings"
        default:
            return error.localizedDescription
        }
    }
}
