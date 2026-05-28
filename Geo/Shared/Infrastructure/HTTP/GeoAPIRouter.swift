import Foundation
import os.log

private let apiLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "GeoAPIRouter")

final class GeoAPIRouter: @unchecked Sendable {
    private let registry: MCPToolRegistry
    private let tokens: APITokenStore
    private let pending: PendingTransactionStore
    private let blocks: any BlocksRepository

    init(
        registry: MCPToolRegistry,
        tokens: APITokenStore = .shared,
        pending: PendingTransactionStore = .shared,
        blocks: any BlocksRepository
    ) {
        self.registry = registry
        self.tokens = tokens
        self.pending = pending
        self.blocks = blocks
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let route = "\(request.method) \(request.path)"
        let required = requiredScope(for: request)

        guard let auth = request.headers["authorization"], let raw = bearerToken(auth) else {
            return missingAuth()
        }
        guard let token = tokens.validate(rawToken: raw) else {
            return rotatedAuth()
        }
        if !token.scope.allows(required) {
            return tagCaller(.error(403, "insufficient scope: requires \(required.rawValue)"), token.callerId)
        }

        let response = await dispatch(request: request, token: token)
        return tagCaller(response, token.callerId)
    }

    private func tagCaller(_ resp: HTTPResponse, _ callerId: String) -> HTTPResponse {
        var r = resp
        r.headers["X-Geo-Caller"] = callerId
        return r
    }

    private func bearerToken(_ header: String) -> String? {
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1])
    }

    private func missingAuth() -> HTTPResponse {
        .error(401, "missing bearer token", extraHeaders: ["WWW-Authenticate": "Bearer realm=\"geo-api\""])
    }

    private func rotatedAuth() -> HTTPResponse {
        .error(401, "invalid or rotated token", extraHeaders: ["WWW-Authenticate": "Bearer realm=\"rotated\""])
    }

    private func requiredScope(for request: HTTPRequest) -> TokenScope {
        let method = request.method
        let path = request.path
        if method == "DELETE" { return .readWriteDestructive }
        if path.hasPrefix("/v1/destructive/") { return .readWriteDestructive }
        if method == "POST" || method == "PATCH" || method == "PUT" { return .readWrite }
        return .read
    }

    private func dispatch(request: HTTPRequest, token: ValidatedToken) async -> HTTPResponse {
        let path = request.path
        let method = request.method

        if method == "GET" {
            switch path {
            case "/v1/blocks/orphans":
                return await call("find_orphans", args: [:])
            case "/v1/blocks/unresolved-links":
                return await call("find_unresolved_links", args: [:])
            case "/v1/graph/snapshot":
                var args: [String: AnyCodableValue] = [:]
                if let l = request.query["limit"].flatMap(Int.init) { args["limit"] = .int(l) }
                return await call("get_graph_snapshot", args: args)
            case "/v1/blocks":
                var args: [String: AnyCodableValue] = [:]
                if let l = request.query["limit"].flatMap(Int.init) { args["limit"] = .int(l) }
                if let t = request.query["tag_name"] { args["tag_name"] = .string(t) }
                return await call("list_blocks", args: args)
            case "/v1/blocks/by-title":
                guard let title = request.query["title"] else { return .error(400, "title query required") }
                return await call("get_block_by_title", args: ["title": .string(title)])
            case "/v1/blocks/by-status":
                guard let status = request.query["status"] else { return .error(400, "status query required") }
                return await call("list_by_status", args: ["status": .string(status)])
            case "/v1/blocks/by-type":
                guard let type = request.query["type"] else { return .error(400, "type query required") }
                return await call("list_by_type", args: ["type": .string(type)])
            case "/v1/blocks/search":
                guard let q = request.query["q"] else { return .error(400, "q query required") }
                return await call("search_blocks", args: ["query": .string(q)])
            case "/v1/tasks":
                var args: [String: AnyCodableValue] = [:]
                if let s = request.query["status"] { args["status"] = .string(s) }
                if let k = request.query["kind"] { args["kind"] = .string(k) }
                if let p = request.query["priority"] { args["priority"] = .string(p) }
                if let lb = request.query["linked_block_id"] { args["linked_block_id"] = .string(lb) }
                return await call("list_tasks", args: args)
            case "/v1/tasks/upcoming":
                var args: [String: AnyCodableValue] = [:]
                if let w = request.query["window"] { args["window"] = .string(w) }
                if let l = request.query["limit"].flatMap(Int.init) { args["limit"] = .int(l) }
                return await call("list_upcoming", args: args)
            case "/v1/tags":
                return await call("list_tags", args: [:])
            case "/v1/days/today":
                return await call("get_today", args: [:])
            default:
                break
            }

            if let id = pathParam(path: path, prefix: "/v1/blocks/", suffix: "/neighbors") {
                return await call("list_neighbors", args: ["id": .string(id)])
            }
            if let id = pathParam(path: path, prefix: "/v1/blocks/", suffix: "/backlinks") {
                return await call("find_backlinks", args: ["block_id": .string(id)])
            }
            if let id = pathParam(path: path, prefix: "/v1/blocks/", suffix: nil), !id.contains("/") {
                return await call("get_block", args: ["id": .string(id)])
            }
            if let id = pathParam(path: path, prefix: "/v1/tasks/", suffix: nil), !id.contains("/") {
                return await call("get_task", args: ["id": .string(id)])
            }
            if let date = pathParam(path: path, prefix: "/v1/tasks/for-day/", suffix: nil), !date.contains("/") {
                return await call("list_tasks_for_day", args: ["date": .string(date)])
            }
            if let date = pathParam(path: path, prefix: "/v1/days/", suffix: nil), !date.contains("/") {
                return await call("get_day", args: ["date": .string(date)])
            }
        } else if method == "POST" || method == "PATCH" {
            let body = parseJSONBody(request.body)
            switch path {
            case "/v1/blocks":
                return await call("create_block", args: body)
            case "/v1/tasks":
                return await call("create_task", args: body)
            case "/v1/tasks/parse":
                return await call("ai_quick_add_parse", args: body)
            case "/v1/tags":
                return await call("create_tag", args: body)
            case "/v1/destructive/prepare":
                return await prepareDestructive(body: body, token: token)
            default:
                break
            }

            if path.hasPrefix("/v1/destructive/commit/") {
                let txId = String(path.dropFirst("/v1/destructive/commit/".count))
                return await commitDestructive(txId: txId, body: body, token: token)
            }
            if let id = pathParam(path: path, prefix: "/v1/blocks/", suffix: "/tag") {
                var args = body
                args["block_id"] = .string(id)
                return await call("set_block_tag", args: args)
            }
            if let id = pathParam(path: path, prefix: "/v1/blocks/", suffix: "/layer") {
                var args = body
                args["id"] = .string(id)
                return await call("set_layer", args: args)
            }
            if let id = pathParam(path: path, prefix: "/v1/blocks/", suffix: "/extract-permanent") {
                return await call("extract_permanent_from", args: ["id": .string(id)])
            }
            if let id = pathParam(path: path, prefix: "/v1/blocks/", suffix: "/promote-permanent") {
                return await call("promote_to_permanent", args: ["id": .string(id)])
            }
            if let id = pathParam(path: path, prefix: "/v1/blocks/", suffix: "/link-day") {
                var args = body
                args["block_id"] = .string(id)
                return await call("link_block_to_day", args: args)
            }
            if let id = pathParam(path: path, prefix: "/v1/blocks/", suffix: nil), method == "PATCH" {
                var args = body
                args["id"] = .string(id)
                return await call("update_block", args: args)
            }
            if let id = pathParam(path: path, prefix: "/v1/tasks/", suffix: "/complete") {
                return await call("complete_task", args: ["id": .string(id)])
            }
            if let id = pathParam(path: path, prefix: "/v1/tasks/", suffix: "/reminder") {
                var args = body
                args["id"] = .string(id)
                return await call("add_reminder", args: args)
            }
            if let id = pathParam(path: path, prefix: "/v1/tasks/", suffix: nil), method == "PATCH" {
                var args = body
                args["id"] = .string(id)
                return await call("update_task", args: args)
            }
            if let date = pathParam(path: path, prefix: "/v1/days/", suffix: "/habit") {
                var args = body
                args["date"] = .string(date)
                return await call("record_habit_occurrence", args: args)
            }
        } else if method == "DELETE" {
            if let id = pathParam(path: path, prefix: "/v1/blocks/", suffix: nil) {
                return await preparedDeleteBlock(targetId: id, request: request, token: token)
            }
            if let id = pathParam(path: path, prefix: "/v1/tasks/", suffix: nil) {
                return await preparedDeleteTask(targetId: id, request: request, token: token)
            }
        }

        return .error(404, "no route for \(method) \(path)")
    }

    private func parseJSONBody(_ data: Data) -> [String: AnyCodableValue] {
        guard !data.isEmpty else { return [:] }
        if let parsed = try? JSONDecoder().decode(AnyCodableValue.self, from: data),
           case .object(let obj) = parsed {
            return obj
        }
        return [:]
    }

    private func pathParam(path: String, prefix: String, suffix: String?) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        if let suffix {
            guard rest.hasSuffix(suffix) else { return nil }
            let id = String(rest.dropLast(suffix.count))
            return id.isEmpty ? nil : id
        }
        return rest.isEmpty ? nil : rest
    }

    private func call(_ toolName: String, args: [String: AnyCodableValue]) async -> HTTPResponse {
        do {
            let result = try await registry.call(name: toolName, arguments: args)
            return toolResultToResponse(result)
        } catch {
            apiLogger.error("tool \(toolName) failed: \(error.localizedDescription)")
            return .error(500, "tool failed")
        }
    }

    private func toolResultToResponse(_ result: MCPToolResult) -> HTTPResponse {
        let text = result.content.first?.text ?? ""
        let isError = result.isError ?? false
        if isError {
            let status: Int = text.lowercased().contains("not found") ? 404 : 400
            return .error(status, text)
        }
        if text.isEmpty { return .empty(204) }
        if let value = try? JSONDecoder().decode(AnyCodableValue.self, from: Data(text.utf8)) {
            return .json(200, value)
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json; charset=utf-8"], body: Data(text.utf8))
    }

    // MARK: - Destructive two-phase

    private func prepareDestructive(body: [String: AnyCodableValue], token: ValidatedToken) async -> HTTPResponse {
        guard let opRaw = body["operation"]?.stringValue,
              let op = DestructiveOp(rawValue: opRaw),
              let targetId = body["target_id"]?.stringValue else {
            return .error(400, "operation and target_id required")
        }

        var blockVersion: Int?
        var diffPreview = ""

        switch op {
        case .deleteBlock:
            do {
                let all = try await blocks.list()
                guard let block = all.first(where: { $0.id == targetId }) else {
                    return .error(404, "block not found")
                }
                blockVersion = MarkdownConverter.shared.frontmatterVersion(in: block.markdown)
                diffPreview = "delete block: \(block.displayTitle) (\(block.id))"
            } catch {
                return .error(500, "failed to load block")
            }
        case .deleteTask:
            diffPreview = "delete task: \(targetId)"
        }

        do {
            let op = try pending.prepare(
                operation: op,
                targetId: targetId,
                blockVersion: blockVersion,
                diffPreview: diffPreview,
                callerId: token.callerId
            )
            var payload: [String: AnyCodableValue] = [
                "transaction_id": .string(op.transactionId),
                "operation": .string(op.operation.rawValue),
                "target_id": .string(op.targetId),
                "diff_preview": .string(op.diffPreview),
                "expires_in_seconds": .int(Int(PendingTransactionStore.ttl)),
            ]
            if let bv = op.blockVersion { payload["block_version"] = .int(bv) }
            return .json(200, .object(payload))
        } catch PendingError.overflow {
            return .error(429, "too many pending transactions")
        } catch {
            return .error(500, "prepare failed")
        }
    }

    private func commitDestructive(txId: String, body: [String: AnyCodableValue], token: ValidatedToken) async -> HTTPResponse {
        let expected = body["block_version"]?.intValue
        let op: PendingOp
        do {
            op = try pending.consume(transactionId: txId, expectedBlockVersion: expected)
        } catch PendingError.notFound {
            return .error(404, "transaction not found")
        } catch PendingError.expired {
            return .error(410, "transaction expired")
        } catch PendingError.staleVersion {
            return .error(409, "block_version stale")
        } catch {
            return .error(500, "commit failed")
        }

        if op.callerId != token.callerId {
            return .error(403, "transaction owner mismatch")
        }

        switch op.operation {
        case .deleteBlock:
            if let prepared = op.blockVersion {
                do {
                    let all = try await blocks.list()
                    guard let current = all.first(where: { $0.id == op.targetId }) else {
                        return .error(404, "block disappeared")
                    }
                    let currentVersion = MarkdownConverter.shared.frontmatterVersion(in: current.markdown)
                    if currentVersion != prepared {
                        return .error(409, "block_version changed since prepare")
                    }
                } catch {
                    return .error(500, "version recheck failed")
                }
            }
            return await call("delete_block", args: ["id": .string(op.targetId)])
        case .deleteTask:
            return await call("delete_task", args: ["id": .string(op.targetId)])
        }
    }

    private func preparedDeleteBlock(targetId: String, request: HTTPRequest, token: ValidatedToken) async -> HTTPResponse {
        let body = parseJSONBody(request.body)
        guard let txId = body["transaction_id"]?.stringValue else {
            return .error(400, "DELETE requires transaction_id from prepare")
        }
        return await commitDestructive(txId: txId, body: body, token: token)
    }

    private func preparedDeleteTask(targetId: String, request: HTTPRequest, token: ValidatedToken) async -> HTTPResponse {
        let body = parseJSONBody(request.body)
        guard let txId = body["transaction_id"]?.stringValue else {
            return .error(400, "DELETE requires transaction_id from prepare")
        }
        return await commitDestructive(txId: txId, body: body, token: token)
    }
}
