import Foundation

enum BridgeEndpoint {
    case health
    case termInput(session: String)
    case termWinsize(session: String)
    case termResize(session: String)
    case termStream(session: String)
    case termKill(session: String)
    case termRename(session: String, to: String)
    case termList
    case termPreview(session: String, lines: Int)
    case termAgents
    case termAttachAgent(project: String, pane: String)
    case termAttachHerdr(project: String)
    case termAgentChat(project: String, pane: String, limit: Int)
    case termAgentPrompt(project: String, pane: String)
    case termAgentCommands(project: String, pane: String)
    case termAgentUpload(project: String, pane: String)
    case termUpload
    case tasksList
    case tasksCreate
    case taskComplete(id: String)
    case taskReopen(id: String)
    case taskDelete(id: String)
    case vitalsProtocol
    case vitalsState
    case vitalsLogs
    case vitalsLog

    var path: String {
        switch self {
        case .health:
            return "/health"
        case .termInput(let session):
            return "/term/input?session=\(Self.encode(session))"
        case .termWinsize(let session):
            return "/term/winsize?session=\(Self.encode(session))"
        case .termResize(let session):
            return "/term/resize?session=\(Self.encode(session))"
        case .termStream(let session):
            return "/term/stream?session=\(Self.encode(session))"
        case .termKill(let session):
            return "/term/kill?session=\(Self.encode(session))"
        case .termRename(let session, let to):
            return "/term/rename?session=\(Self.encode(session))&to=\(Self.encode(to))"
        case .termList:
            return "/term/list"
        case .termPreview(let session, let lines):
            return "/term/preview?session=\(Self.encode(session))&lines=\(max(1, min(40, lines)))"
        case .termAgents:
            return "/term/agents"
        case .termAttachAgent(let project, let pane):
            return "/term/attach-agent?project=\(Self.encode(project))&pane=\(Self.encode(pane))"
        case .termAttachHerdr(let project):
            return "/term/attach-herdr?project=\(Self.encode(project))"
        case .termAgentChat(let project, let pane, let limit):
            return "/term/agent-chat?project=\(Self.encode(project))&pane=\(Self.encode(pane))&limit=\(max(1, min(200, limit)))"
        case .termAgentPrompt(let project, let pane):
            return "/term/agent-prompt?project=\(Self.encode(project))&pane=\(Self.encode(pane))"
        case .termAgentCommands(let project, let pane):
            return "/term/agent-commands?project=\(Self.encode(project))&pane=\(Self.encode(pane))"
        case .termAgentUpload(let project, let pane):
            return "/term/agent-upload?project=\(Self.encode(project))&pane=\(Self.encode(pane))"
        case .termUpload:
            return "/term/upload"
        case .tasksList, .tasksCreate:
            return "/tasks"
        case .taskComplete(let id):
            return "/tasks/\(Self.encode(id))/complete"
        case .taskReopen(let id):
            return "/tasks/\(Self.encode(id))/reopen"
        case .taskDelete(let id):
            return "/tasks/\(Self.encode(id))"
        case .vitalsProtocol:
            return "/vitals/protocol"
        case .vitalsState:
            return "/vitals/state"
        case .vitalsLogs:
            return "/vitals/logs"
        case .vitalsLog:
            return "/vitals/log"
        }
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowedCharacters)!
    }

    private static let allowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
