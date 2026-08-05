import Foundation
import GeoCore

struct ServiceCheck: Identifiable {
    enum Outcome {
        case pending
        case running
        case ok
        case failed
        case unavailable
    }

    let id: String
    let name: String
    var outcome: Outcome = .pending
    var status: String = "—"
    var detail: String = ""
    var hint: String?

    var isFilled: Bool { outcome == .ok }
}

@MainActor
final class ServiceStatusViewModel: ObservableObject {
    @Published private(set) var checks: [ServiceCheck]
    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: Date?

    private let client: any BridgeAPI
    private let tasks: BridgeTasksRepository

    private static let hubID = "hub"
    private static let tasksID = "tasks"
    private static let terminalID = "terminal"
    private static let macID = "mac"

    init(client: any BridgeAPI = BridgeClient.shared) {
        self.client = client
        self.tasks = BridgeTasksRepository(client: client)
        self.checks = [
            ServiceCheck(id: Self.hubID, name: "hub (vm)"),
            ServiceCheck(id: Self.tasksID, name: "tasks"),
            ServiceCheck(id: Self.terminalID, name: "terminal"),
            ServiceCheck(id: Self.macID, name: "sessão mac"),
        ]
    }

    func runChecks() async {
        guard !isRunning else { return }
        isRunning = true
        for index in checks.indices {
            checks[index].outcome = .running
            checks[index].status = "…"
            checks[index].detail = ""
            checks[index].hint = nil
        }
        await checkHub()
        await checkTasks()
        let sessions = await checkTerminal()
        checkMac(sessions: sessions)
        lastRun = Date()
        isRunning = false
    }

    private func checkHub() async {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try await client.health()
            let ms = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            update(Self.hubID, outcome: .ok, status: "\(ms) ms", detail: "GET /health")
        } catch {
            update(Self.hubID, outcome: .failed, status: "falhou", detail: error.localizedDescription)
        }
    }

    private func checkTasks() async {
        do {
            let items = try await tasks.list()
            update(Self.tasksID, outcome: .ok, status: "ok", detail: "\(items.count) tarefas")
        } catch {
            update(Self.tasksID, outcome: .failed, status: "falhou", detail: error.localizedDescription)
        }
    }

    private func checkTerminal() async -> [String] {
        do {
            let data = try await client.getData(
                BridgeEndpoint.termList.path,
                token: BridgeConfig.termToken
            )
            let sessions = try JSONDecoder().decode(TermSessionList.self, from: data).sessions
            let label = sessions.isEmpty ? "nenhuma sessão" : sessions.joined(separator: ", ")
            update(Self.terminalID, outcome: .ok, status: "\(sessions.count) ativas", detail: label)
            return sessions
        } catch {
            update(Self.terminalID, outcome: .failed, status: "falhou", detail: error.localizedDescription)
            return []
        }
    }

    private func checkMac(sessions: [String]) {
        guard checks.first(where: { $0.id == Self.terminalID })?.outcome == .ok else {
            update(
                Self.macID,
                outcome: .unavailable,
                status: "indisponível",
                detail: "sem lista de sessões",
                hint: "Remote Login do Mac"
            )
            return
        }
        if let mac = sessions.first(where: { $0 == "mac" || $0.hasPrefix("mac") }) {
            update(Self.macID, outcome: .ok, status: "ok", detail: "sessão \(mac)")
        } else {
            update(
                Self.macID,
                outcome: .unavailable,
                status: "indisponível",
                detail: "sessão mac ausente",
                hint: "Remote Login do Mac"
            )
        }
    }

    private func update(
        _ id: String,
        outcome: ServiceCheck.Outcome,
        status: String,
        detail: String,
        hint: String? = nil
    ) {
        guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[index].outcome = outcome
        checks[index].status = status
        checks[index].detail = detail
        checks[index].hint = hint
    }
}

private struct TermSessionList: Decodable {
    let sessions: [String]
}
