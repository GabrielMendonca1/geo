import Foundation

enum AnthropicClientError: Error, LocalizedError {
    case missingAPIKey
    case httpFailure(Int, String)
    case invalidResponse
    case parseFailure(String)
    case truncated

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key is not configured. Set it in Settings → AI."
        case .httpFailure(let status, let message):
            return "Anthropic API returned HTTP \(status): \(message)"
        case .invalidResponse:
            return "Anthropic API returned an unexpected response shape."
        case .parseFailure(let detail):
            return "Failed to parse AI response: \(detail)"
        case .truncated:
            return "AI response was truncated before completion."
        }
    }
}

struct ParsedTaskJSON: Codable, Sendable {
    let title: String
    let kind: String
    let priority: String?
    let start_time_iso: String?
    let end_time_iso: String?
    let tag_names: [String]?
    let horizon: String?
    let notes: String?
}

enum AnthropicClient {
    static let model = "claude-haiku-4-5-20251001"
    static let maxTokens = 2048
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let timeoutSeconds: TimeInterval = 10
    static let apiVersion = "2023-06-01"
    static let cacheBeta = "prompt-caching-2024-07-31"
    static let retryDelaysMs: [UInt64] = [500, 1500]
    static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504, 529]

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: [SystemBlock]
        let messages: [Message]

        struct SystemBlock: Encodable {
            let type: String
            let text: String
            let cache_control: CacheControl?

            struct CacheControl: Encodable {
                let type: String
            }
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct ResponseBody: Decodable {
        let content: [ContentBlock]
        let stop_reason: String?

        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
    }

    private struct ErrorBody: Decodable {
        let error: ErrorDetail?

        struct ErrorDetail: Decodable {
            let type: String?
            let message: String?
        }
    }

    static let maxToolIterations: Int = 10
    static let chatMaxTokens: Int = 4096
    static let chatModel: String = "claude-sonnet-4-5-20250929"

    private struct ToolDef: Encodable {
        let name: String
        let description: String
        let input_schema: JSONSchemaObject
        let cache_control: CacheControl?
        struct CacheControl: Encodable { let type: String }
    }

    private struct ChatRequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: [RequestBody.SystemBlock]
        let messages: [WireMessage]
        let tools: [ToolDef]?
    }

    private struct WireMessage: Encodable {
        let role: String
        let content: [WireBlock]
    }

    private enum WireBlock: Encodable {
        case text(String)
        case toolUse(id: String, name: String, input: AnyCodableValue)
        case toolResult(toolUseId: String, content: String, isError: Bool)

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try c.encode("text", forKey: .type)
                try c.encode(s, forKey: .text)
            case .toolUse(let id, let name, let input):
                try c.encode("tool_use", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
                try c.encode(input, forKey: .input)
            case .toolResult(let id, let content, let isError):
                try c.encode("tool_result", forKey: .type)
                try c.encode(id, forKey: .tool_use_id)
                try c.encode(content, forKey: .content)
                if isError { try c.encode(true, forKey: .is_error) }
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, text, id, name, input, tool_use_id, content, is_error
        }
    }

    private struct ChatResponseBody: Decodable {
        let content: [ChatContentBlock]
        let stop_reason: String?
    }

    private struct ChatContentBlock: Decodable {
        let type: String
        let text: String?
        let id: String?
        let name: String?
        let input: AnyCodableValue?
    }

    static func chat(
        messages: [ChatMessage],
        registry: MCPToolRegistry,
        withVaultAccess: Bool = true,
        systemPrompt: String? = nil
    ) async throws -> [ChatMessage] {
        guard let apiKey = AIKeychainService.readKey(), !apiKey.isEmpty else {
            throw AnthropicClientError.missingAPIKey
        }

        let tools: [ToolDef]
        if withVaultAccess {
            let defs = registry.definitions
            tools = defs.enumerated().map { index, def in
                ToolDef(
                    name: def.name,
                    description: def.description,
                    input_schema: def.inputSchema,
                    cache_control: index == defs.count - 1 ? .init(type: "ephemeral") : nil
                )
            }
        } else {
            tools = []
        }

        let systemBlocks: [RequestBody.SystemBlock] = [
            RequestBody.SystemBlock(
                type: "text",
                text: systemPrompt ?? chatSystemPrompt,
                cache_control: RequestBody.SystemBlock.CacheControl(type: "ephemeral")
            )
        ]

        var conversation = messages
        var iterations = 0

        while iterations < maxToolIterations {
            let wireMessages = conversation.map { msg -> WireMessage in
                let blocks = msg.blocks.map { block -> WireBlock in
                    switch block {
                    case .text(let s): return .text(s)
                    case .toolUse(let id, let name, let input): return .toolUse(id: id, name: name, input: input)
                    case .toolResult(let id, let content, let isError): return .toolResult(toolUseId: id, content: content, isError: isError)
                    }
                }
                return WireMessage(role: msg.role.rawValue, content: blocks)
            }

            let body = ChatRequestBody(
                model: chatModel,
                max_tokens: chatMaxTokens,
                system: systemBlocks,
                messages: wireMessages,
                tools: tools.isEmpty ? nil : tools
            )

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
            request.setValue(cacheBeta, forHTTPHeaderField: "anthropic-beta")

            do {
                let encoder = JSONEncoder()
                request.httpBody = try encoder.encode(body)
            } catch {
                throw AnthropicClientError.parseFailure("chat request encode: \(error.localizedDescription)")
            }

            let (data, http) = try await sendWithRetry(request: request)
            guard (200..<300).contains(http.statusCode) else {
                let message: String
                if let decoded = try? JSONDecoder().decode(ErrorBody.self, from: data),
                   let detail = decoded.error?.message {
                    message = detail
                } else {
                    message = String(data: data, encoding: .utf8) ?? "unknown error"
                }
                throw AnthropicClientError.httpFailure(http.statusCode, message)
            }

            let decoded: ChatResponseBody
            do {
                decoded = try JSONDecoder().decode(ChatResponseBody.self, from: data)
            } catch {
                throw AnthropicClientError.parseFailure("chat response decode: \(error.localizedDescription)")
            }

            var assistantBlocks: [ChatMessage.Block] = []
            var toolUses: [(id: String, name: String, input: AnyCodableValue)] = []
            for block in decoded.content {
                switch block.type {
                case "text":
                    if let t = block.text { assistantBlocks.append(.text(t)) }
                case "tool_use":
                    if let id = block.id, let name = block.name {
                        let input = block.input ?? .object([:])
                        assistantBlocks.append(.toolUse(id: id, name: name, input: input))
                        toolUses.append((id, name, input))
                    }
                default:
                    continue
                }
            }
            conversation.append(ChatMessage(role: .assistant, blocks: assistantBlocks))

            if toolUses.isEmpty {
                return conversation
            }

            var resultBlocks: [ChatMessage.Block] = []
            for use in toolUses {
                let args: [String: AnyCodableValue]
                if case .object(let obj) = use.input {
                    args = obj
                } else {
                    args = [:]
                }
                let result: MCPToolResult
                do {
                    result = try await registry.call(name: use.name, arguments: args)
                } catch {
                    result = .error("tool execution failed: \(error.localizedDescription)")
                }
                let combinedText = result.content.map(\.text).joined(separator: "\n")
                resultBlocks.append(.toolResult(
                    toolUseId: use.id,
                    content: combinedText,
                    isError: result.isError ?? false
                ))
            }
            conversation.append(ChatMessage(role: .user, blocks: resultBlocks))
            iterations += 1
        }

        throw AnthropicClientError.toolUseLoopExceeded
    }

    private static let chatSystemPrompt: String = {
        """
        You are Geo's in-app assistant. Geo is a personal knowledge base of markdown blocks (notes), tasks, tags, and day records.

        You have direct read access to the user's vault via tools. Use list_blocks, get_block, search_blocks, get_block_by_title to answer questions about the user's notes. Prefer search_blocks when looking for content; use list_blocks then get_block when you need full markdown.

        Writing rules:
        - You may create new blocks (create_block) and update/delete blocks on the agent/review/shared layers.
        - You may NOT directly write to user-layer blocks. If asked, create a review-layer block with the proposed change instead.
        - Be concise. Quote the user's own words when relevant.
        - If a tool returns an error, surface it plainly — do not fabricate data.
        """
    }()

    static func parseTask(input: String, nowISO: String) async throws -> ParsedTaskJSON {
        guard let apiKey = AIKeychainService.readKey(), !apiKey.isEmpty else {
            throw AnthropicClientError.missingAPIKey
        }

        let body = RequestBody(
            model: model,
            max_tokens: maxTokens,
            system: [
                RequestBody.SystemBlock(
                    type: "text",
                    text: staticSystemPrompt,
                    cache_control: RequestBody.SystemBlock.CacheControl(type: "ephemeral")
                ),
                RequestBody.SystemBlock(
                    type: "text",
                    text: "Current time (ISO 8601 UTC): \(nowISO)",
                    cache_control: nil
                )
            ],
            messages: [RequestBody.Message(role: "user", content: input)]
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(cacheBeta, forHTTPHeaderField: "anthropic-beta")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw AnthropicClientError.parseFailure("request encode: \(error.localizedDescription)")
        }

        let (data, http) = try await sendWithRetry(request: request)

        guard (200..<300).contains(http.statusCode) else {
            let message: String
            if let decoded = try? JSONDecoder().decode(ErrorBody.self, from: data),
               let detail = decoded.error?.message {
                message = detail
            } else {
                message = String(data: data, encoding: .utf8) ?? "unknown error"
            }
            throw AnthropicClientError.httpFailure(http.statusCode, message)
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw AnthropicClientError.parseFailure("response decode: \(error.localizedDescription)")
        }

        if decoded.stop_reason == "max_tokens" {
            throw AnthropicClientError.truncated
        }

        guard let rawText = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw AnthropicClientError.invalidResponse
        }

        let cleaned = stripCodeFences(rawText)
        return try decodeTaskJSON(cleaned)
    }

    private static func sendWithRetry(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AnthropicClientError.invalidResponse
                }
                if retryableStatuses.contains(http.statusCode), attempt < retryDelaysMs.count {
                    try await Task.sleep(nanoseconds: retryDelaysMs[attempt] * 1_000_000)
                    attempt += 1
                    continue
                }
                return (data, http)
            } catch {
                if error is AnthropicClientError { throw error }
                if attempt < retryDelaysMs.count {
                    try? await Task.sleep(nanoseconds: retryDelaysMs[attempt] * 1_000_000)
                    attempt += 1
                    continue
                }
                throw AnthropicClientError.httpFailure(-1, error.localizedDescription)
            }
        }
    }

    private static func decodeTaskJSON(_ cleaned: String) throws -> ParsedTaskJSON {
        if let data = cleaned.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(ParsedTaskJSON.self, from: data) {
            return parsed
        }

        let repaired = repairJSON(cleaned)
        guard let data = repaired.data(using: .utf8) else {
            throw AnthropicClientError.parseFailure("text is not utf8")
        }
        do {
            return try JSONDecoder().decode(ParsedTaskJSON.self, from: data)
        } catch {
            throw AnthropicClientError.parseFailure("json decode: \(error.localizedDescription)")
        }
    }

    private static func repairJSON(_ raw: String) -> String {
        var text = raw
        if let firstBrace = text.firstIndex(of: "{") {
            text = String(text[firstBrace...])
        }
        if let lastBrace = text.lastIndex(of: "}") {
            text = String(text[...lastBrace])
        }
        text = replaceSingleQuotedKeys(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceSingleQuotedKeys(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" {
                var j = i + 1
                while j < chars.count, chars[j] != "'", chars[j] != "\n" { j += 1 }
                if j < chars.count, chars[j] == "'" {
                    var k = j + 1
                    while k < chars.count, chars[k].isWhitespace { k += 1 }
                    if k < chars.count, chars[k] == ":" {
                        result.append("\"")
                        result.append(contentsOf: chars[(i + 1)..<j])
                        result.append("\"")
                        i = j + 1
                        continue
                    }
                }
            }
            result.append(c)
            i += 1
        }
        return result
    }

    private static func stripCodeFences(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            } else {
                text = String(text.dropFirst(3))
            }
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let staticSystemPrompt: String = {
        """
        You are a task parser for Geo, a productivity app. Parse the user's natural-language input into a structured task JSON.

        Return ONLY valid JSON — no prose, no code fences. Schema:
        {
          "title": string,
          "kind": "task"|"event"|"habit"|"milestone",
          "priority": "urgent"|"high"|"medium"|"low"|"unset",
          "start_time_iso": string|null,
          "end_time_iso": string|null,
          "tag_names": [string]|null,
          "horizon": "day"|"week"|"month"|"none",
          "notes": string|null
        }

        Rules:
        - Meeting / call / reunion → kind=event. Recurring habit language (every day, toda manha) → kind=habit. Deadline/ship/deliver language with a date >7 days out → kind=milestone. Else → task.
        - Default horizon: today=day, this week=week, this month/>7d out=month, no date=none.
        - If input is Portuguese, still fill the fields correctly (title stays in original language).
        - Be conservative: null over hallucination for time/tags.
        """
    }()
}
