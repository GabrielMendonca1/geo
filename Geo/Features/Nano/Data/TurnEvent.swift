import Foundation

enum TurnEvent: Sendable {
    case text(delta: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(id: String, content: JSONValue, isError: Bool)
    case done(reply: String?)
    case failure(message: String)
}

enum TurnEventDecoder {
    static func decode(line: Data) -> TurnEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }

        if let errorMessage = obj["error"] as? String {
            return .failure(message: errorMessage)
        }

        if let result = obj["result"] as? [String: Any] {
            let reply = result["reply"] as? String
            return .done(reply: reply)
        }
        if obj["result"] is NSNull {
            return .done(reply: nil)
        }

        guard let type = obj["type"] as? String else { return nil }
        switch type {
        case "text":
            let delta = obj["delta"] as? String ?? ""
            return .text(delta: delta)
        case "tool_use":
            let id = obj["toolUseId"] as? String ?? ""
            let name = obj["name"] as? String ?? ""
            let input = jsonValue(from: obj["input"])
            return .toolUse(id: id, name: name, input: input)
        case "tool_result":
            let id = obj["toolUseId"] as? String ?? ""
            let content = jsonValue(from: obj["content"])
            let isError = obj["isError"] as? Bool ?? false
            return .toolResult(id: id, content: content, isError: isError)
        default:
            return nil
        }
    }

    private static func jsonValue(from any: Any?) -> JSONValue {
        guard let any else { return .null }
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed]) else {
            return .null
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
}
