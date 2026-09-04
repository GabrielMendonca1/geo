import Foundation

enum AgentTargetRef: Hashable {
    case pane(project: String, pane: String)
    case session(String)
}

enum BridgeEndpoint {
    case health
    case termInput(session: String)
    case termWinsize(session: String)
    case termResize(session: String)
    case termStream(session: String)
    case termKill(session: String)
    case termRename(session: String, to: String)
    case termList
    case termHealth
    case termAgents
    case termAttachAgent(project: String, pane: String)
    case termAttachHerdr(project: String)
    case termAgentChat(target: AgentTargetRef, limit: Int)
    case termAgentWork(target: AgentTargetRef)
    case termAgentPrompt(target: AgentTargetRef)
    case termAgentCommands(target: AgentTargetRef)
    case termAgentUpload(target: AgentTargetRef)
    case termAgentAsk(target: AgentTargetRef)
    case termAgentAnswer(session: String)
    case termAgentInterrupt(session: String)
    case termAgentStart(session: String)
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
    case vitalsCatalog
    case vitalsBlocks
    case vitalsPlan(week: String)

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
        case .termHealth:
            return "/term/health"
        case .termAgents:
            return "/term/agents"
        case .termAttachAgent(let project, let pane):
            return "/term/attach-agent?project=\(Self.encode(project))&pane=\(Self.encode(pane))"
        case .termAttachHerdr(let project):
            return "/term/attach-herdr?project=\(Self.encode(project))"
        case .termAgentChat(let target, let limit):
            return "/term/agent-chat?\(Self.selector(target))&limit=\(max(1, min(200, limit)))"
        case .termAgentWork(let target):
            return "/term/agent-work?\(Self.selector(target))"
        case .termAgentPrompt(let target):
            return "/term/agent-prompt?\(Self.selector(target))"
        case .termAgentCommands(let target):
            return "/term/agent-commands?\(Self.selector(target))"
        case .termAgentUpload(let target):
            return "/term/agent-upload?\(Self.selector(target))"
        case .termAgentAsk(let target):
            return "/term/agent-ask?\(Self.selector(target))"
        case .termAgentAnswer(let session):
            return "/term/agent-answer?session=\(Self.encode(session))"
        case .termAgentInterrupt(let session):
            return "/term/agent-interrupt?session=\(Self.encode(session))"
        case .termAgentStart(let session):
            return "/term/agent-start?session=\(Self.encode(session))"
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
        case .vitalsCatalog:
            return "/vitals/catalog"
        case .vitalsBlocks:
            return "/vitals/blocks"
        case .vitalsPlan(let week):
            return "/vitals/plan?week=\(Self.encode(week))"
        }
    }

    private static func selector(_ target: AgentTargetRef) -> String {
        switch target {
        case .pane(let project, let pane):
            return "project=\(encode(project))&pane=\(encode(pane))"
        case .session(let session):
            return "session=\(encode(session))"
        }
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowedCharacters)!
    }

    private static let allowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
