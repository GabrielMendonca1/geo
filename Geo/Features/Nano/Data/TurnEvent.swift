import Foundation

enum TurnEvent: Sendable {
    case text(delta: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(id: String, content: JSONValue, isError: Bool)
    case toolPartial(callID: String, partial: JSONValue)
    case agentDispatch(workspaceID: String, status: String, lastLine: String?)
    case done(reply: String?)
    case failure(message: String)
}
