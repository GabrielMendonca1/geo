import SwiftUI

struct TermAgentUnit: Decodable, Identifiable, Equatable {
    let name: String
    let active: Bool
    let since: String

    var id: String { name }
}

struct TermAgentProcess: Decodable, Identifiable, Equatable {
    let host: String
    let agent: String
    let status: String
    let title: String
    let project: String
    let cwd: String
    let pane: String
    let session: String

    var id: String {
        let key = pane.isEmpty ? (session.isEmpty ? title : session) : pane
        return "\(host)|\(project)|\(agent)|\(key)"
    }

    var isBusy: Bool { status == "working" || status == "running" }
    var isIdle: Bool { status == "idle" }
    var isAttachable: Bool { host == "mac" && !pane.isEmpty && !project.isEmpty }

    var chatRef: AgentTargetRef? {
        if host == "mac" {
            return isAttachable ? .pane(project: project, pane: pane) : nil
        }
        return session.isEmpty ? nil : .session(session)
    }

    var isChattable: Bool { chatRef != nil }

    var place: String {
        let name = cwd.split(separator: "/").last.map(String.init) ?? ""
        return name == project ? "" : name
    }

    enum CodingKeys: String, CodingKey {
        case host, agent, status, title, project, cwd, pane, session
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? ""
        }
        host = text(.host)
        agent = text(.agent)
        status = text(.status)
        title = text(.title)
        project = text(.project)
        cwd = text(.cwd)
        pane = text(.pane)
        session = text(.session)
    }
}

struct TermAttachPayload: Decodable {
    let session: String
}

/// Sessão do herdr (multiplexador do Mac), como o bridge reporta em `/term/herdr-sessions`.
struct HerdrSession: Decodable, Identifiable, Equatable {
    let name: String
    let status: String
    let directory: String

    var id: String { name }
    var running: Bool { status == "running" }
    var note: String { running ? "rodando" : "parada" }

    enum CodingKeys: String, CodingKey {
        case name, status, directory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? ""
        }
        name = text(.name)
        status = text(.status)
        directory = text(.directory)
    }
}

struct HerdrSessionsPayload: Decodable {
    let macOnline: Bool
    let sessions: [HerdrSession]

    enum CodingKeys: String, CodingKey {
        case macOnline = "mac_online"
        case sessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macOnline = ((try? container.decodeIfPresent(Bool.self, forKey: .macOnline)) ?? nil) ?? false
        let decoded = (try? container.decodeIfPresent([HerdrSession].self, forKey: .sessions)) ?? nil
        sessions = (decoded ?? []).filter { !$0.name.isEmpty }
    }
}

struct TermAgentsPayload: Decodable {
    let units: [TermAgentUnit]
    let macOnline: Bool
    let agents: [TermAgentProcess]

    enum CodingKeys: String, CodingKey {
        case units
        case macOnline = "mac_online"
        case agents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        units = try container.decode([TermAgentUnit].self, forKey: .units)
        macOnline = (try? container.decode(Bool.self, forKey: .macOnline)) ?? false
        let decoded = (try? container.decodeIfPresent([TermAgentProcess].self, forKey: .agents)) ?? nil
        agents = (decoded ?? []).filter { !$0.agent.isEmpty }
    }
}

struct TermAgentGroup: Identifiable, Equatable {
    let project: String
    let agents: [TermAgentProcess]

    var id: String { project }
    var label: String { project.isEmpty ? "sem projeto" : project }

    var hasBusy: Bool { agents.contains(where: \.isBusy) }

    var level: StatusLevel {
        if hasBusy { return .working }
        if agents.contains(where: \.isIdle) { return .idle }
        return .dormant
    }

    var marks: (symbols: [String], overflow: Int) {
        let symbols = agents.prefix(5).map { AgentMark.symbol(for: $0.agent) ?? AgentMark.glyph(for: $0.agent) }
        return (symbols, max(0, agents.count - 5))
    }
}

enum TermAgentOrder {
    static func grouped(_ agents: [TermAgentProcess]) -> [TermAgentGroup] {
        var groups: [TermAgentGroup] = []
        for agent in sorted(agents) {
            if let last = groups.last, last.project == agent.project {
                groups[groups.count - 1] = TermAgentGroup(project: last.project, agents: last.agents + [agent])
            } else {
                groups.append(TermAgentGroup(project: agent.project, agents: [agent]))
            }
        }
        return groups
    }

    static func ranked(_ groups: [TermAgentGroup]) -> [TermAgentGroup] {
        groups.enumerated().sorted { lhs, rhs in
            if lhs.element.project.isEmpty != rhs.element.project.isEmpty {
                return rhs.element.project.isEmpty
            }
            if lhs.element.hasBusy != rhs.element.hasBusy {
                return lhs.element.hasBusy
            }
            if lhs.element.project != rhs.element.project {
                return lhs.element.project < rhs.element.project
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    static func autoExpanded(_ groups: [TermAgentGroup]) -> Set<String> {
        var open = Set(groups.filter(\.hasBusy).map(\.project))
        open.insert("")
        return open
    }

    static func merged(layout: [TermAgentGroup], live: [TermAgentProcess]) -> [TermAgentGroup] {
        var fresh: [String: TermAgentProcess] = [:]
        for agent in live { fresh[agent.id] = agent }
        var kept = Set<String>()
        var result: [TermAgentGroup] = []
        for group in layout {
            let agents = group.agents.compactMap { fresh[$0.id] }
            guard !agents.isEmpty else { continue }
            agents.forEach { kept.insert($0.id) }
            result.append(TermAgentGroup(project: group.project, agents: agents))
        }
        for agent in live where !kept.contains(agent.id) {
            kept.insert(agent.id)
            if let index = result.firstIndex(where: { $0.project == agent.project }) {
                result[index] = TermAgentGroup(project: agent.project, agents: result[index].agents + [agent])
            } else {
                result.append(TermAgentGroup(project: agent.project, agents: [agent]))
            }
        }
        return result
    }

    static func adopting(layout: [TermAgentGroup], live: [TermAgentProcess]) -> [TermAgentGroup] {
        let known = Set(layout.map(\.project))
        return merged(layout: layout, live: live).filter { !known.contains($0.project) }
    }

    static func sorted(_ agents: [TermAgentProcess]) -> [TermAgentProcess] {
        agents.enumerated().sorted { lhs, rhs in
            if lhs.element.project.isEmpty != rhs.element.project.isEmpty {
                return rhs.element.project.isEmpty
            }
            if lhs.element.project != rhs.element.project {
                return lhs.element.project < rhs.element.project
            }
            if rank(lhs.element) != rank(rhs.element) {
                return rank(lhs.element) < rank(rhs.element)
            }
            if lhs.element.agent != rhs.element.agent {
                return lhs.element.agent < rhs.element.agent
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    private static func rank(_ agent: TermAgentProcess) -> Int {
        if agent.isBusy { return 0 }
        if agent.isIdle { return 1 }
        return 2
    }
}

@MainActor
final class SessionsHomeModel: ObservableObject {
    @Published private(set) var serverSessions: [String] = []
    @Published private(set) var serverListLoaded = false
    @Published private(set) var units: [TermAgentUnit] = []
    @Published private(set) var agents: [TermAgentProcess] = []
    @Published private(set) var macOnline = false
    @Published private(set) var reachable = true
    @Published private(set) var work: [String: Int] = [:]
    /// Último resultado bom de `/term/herdr-sessions`: fica em memória pra lista não piscar.
    @Published private(set) var herdr: [HerdrSession] = []
    @Published private(set) var herdrLoaded = false
    @Published private(set) var herdrMacOnline = false

    static let workProbeLimit = 6

    private let client: any BridgeAPI
    private var refreshing = false
    private var starting = false
    private var coalesced = false

    init(client: any BridgeAPI = BridgeClient.shared) {
        self.client = client
    }

    func isDead(_ name: String) -> Bool {
        guard serverListLoaded else { return false }
        return !serverSessions.contains(TerminalSessionList.endpoint(for: name))
    }

    func refresh(force: Bool = true) async {
        guard !refreshing else {
            coalesced = coalesced || force
            return
        }
        refreshing = true
        defer { refreshing = false }
        await cycle()
        if coalesced {
            coalesced = false
            await cycle()
        }
    }

    private func cycle() async {
        let client = self.client
        async let listed = Self.fetch(client, BridgeEndpoint.termList.path, as: TermSessions.self)
        async let probed = Self.fetch(client, BridgeEndpoint.termAgents.path, as: TermAgentsPayload.self)
        async let herded = Self.fetch(client, BridgeEndpoint.termHerdrSessions.path, as: HerdrSessionsPayload.self)

        var ok = false
        if let payload = await probed {
            units = payload.units
            macOnline = payload.macOnline
            agents = TermAgentOrder.sorted(payload.agents)
            ok = true
        }
        async let worked: Void = cycleWork()
        if let list = await listed?.sessions {
            serverSessions = list
            serverListLoaded = true
            ok = true
        }
        await worked
        if let payload = await herded {
            herdr = payload.sessions
            herdrMacOnline = payload.macOnline
            herdrLoaded = true
        }
        reachable = ok
    }

    private func cycleWork() async {
        let client = self.client
        let targets = Array(agents.filter { $0.isBusy && $0.isChattable }.prefix(Self.workProbeLimit))
        let probes = targets.compactMap { agent in
            agent.chatRef.map { (agent.id, BridgeEndpoint.termAgentWork(target: $0).path) }
        }
        var live = work
        for (id, payload) in await Self.fetchWork(client, probes) {
            live[id] = payload.hasWork ? payload.runningAgents : nil
        }
        let ids = Set(targets.map(\.id))
        work = live.filter { ids.contains($0.key) }
    }

    private nonisolated static func fetch<T: Decodable & Sendable>(
        _ client: any BridgeAPI,
        _ path: String,
        as type: T.Type
    ) async -> T? {
        guard let data = try? await client.getData(path, token: BridgeConfig.termToken) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func fetchWork(
        _ client: any BridgeAPI,
        _ probes: [(String, String)]
    ) async -> [(String, AgentWorkPayload)] {
        guard !probes.isEmpty else { return [] }
        return await withTaskGroup(of: (String, AgentWorkPayload?).self) { group in
            for (id, path) in probes {
                group.addTask {
                    (id, await fetch(client, path, as: AgentWorkPayload.self))
                }
            }
            var results: [(String, AgentWorkPayload)] = []
            for await (id, payload) in group {
                if let payload { results.append((id, payload)) }
            }
            return results
        }
    }

    func kill(_ name: String) async {
        let path = BridgeEndpoint.termKill(session: TerminalSessionList.endpoint(for: name)).path
        _ = try? await client.postData(path, body: nil, token: BridgeConfig.termToken)
    }

    func attachAgent(project: String, pane: String) async -> String? {
        await attach(BridgeEndpoint.termAttachAgent(project: project, pane: pane).path)
    }

    func attachHerdr(project: String) async -> String? {
        await attach(BridgeEndpoint.termAttachHerdr(project: project).path)
    }

    private func attach(_ path: String) async -> String? {
        guard let data = try? await client.postData(path, body: nil, token: BridgeConfig.termToken),
              let session = try? JSONDecoder().decode(TermAttachPayload.self, from: data).session,
              !session.isEmpty
        else { return nil }
        return session
    }

    func startAgent(_ name: String, agent: String) async -> AgentStartOutcome? {
        guard !starting else { return nil }
        starting = true
        defer { starting = false }
        let path = BridgeEndpoint.termAgentStart(session: TerminalSessionList.endpoint(for: name)).path
        let body = Data(#"{"agent":"\#(agent)"}"#.utf8)
        do {
            _ = try await client.postData(path, body: body, token: BridgeConfig.termToken)
            return .ok
        } catch BridgeError.server(let status, let code) where status == 409 {
            return code == "already_running" ? .running : .failed
        } catch {
            return .failed
        }
    }

    func rename(_ name: String, to: String) async -> Bool {
        let path = BridgeEndpoint.termRename(session: TerminalSessionList.endpoint(for: name), to: to).path
        do {
            _ = try await client.postData(path, body: nil, token: BridgeConfig.termToken)
            return true
        } catch {
            return false
        }
    }
}

enum AgentStartOutcome {
    case ok
    case running
    case failed
}

enum SessionsHomeStart {
    static let agents = ["claude", "pi", "codex"]

    static func startable(session name: String) -> Bool {
        TerminalSessionList.origin(for: name) != "mac" && !TerminalSessionList.label(for: name).isEmpty
    }

    static func notice(_ outcome: AgentStartOutcome) -> String? {
        switch outcome {
        case .ok: return nil
        case .running: return "já tem agente nessa sessão"
        case .failed: return "falha ao iniciar agente"
        }
    }
}

enum SessionsHomeDisplay {
    static func agentSessions(_ agents: [TermAgentProcess]) -> Set<String> {
        Set(agents.filter { $0.host != "mac" && !$0.session.isEmpty }.map { "vm:\($0.session)" })
    }

    static func rows(_ sessions: [String], agents: [TermAgentProcess]) -> [String] {
        let promoted = agentSessions(agents)
        return sessions.filter { !promoted.contains($0) }
    }
}

enum SessionsHomeKill {
    static func killable(session name: String) -> Bool {
        TerminalSessionList.origin(for: name) != "mac"
            && name != TerminalSessionList.reserved
            && !TerminalSessionList.label(for: name).isEmpty
    }

    static func target(_ agent: TermAgentProcess) -> String? {
        guard case .session(let session)? = agent.chatRef else { return nil }
        let name = "vm:\(session)"
        return killable(session: name) ? name : nil
    }
}

enum SessionsHomeRoute: Hashable {
    case session(String)
    case chat(AgentChatTarget)
    case garime(prefill: String)
}

/// Home da aba Agente no estilo papel: herdr primeiro, terminais salvos e o chat do Garime.
struct SessionsHomeView: View {
    @StateObject private var model = SessionsHomeModel()
    @AppStorage("terminal.sessions") private var sessionsRaw = "vm:mobile"
    @AppStorage(GarimeAgent.sessionKey) private var agentSession = GarimeAgent.fallbackSession
    @State private var path: [SessionsHomeRoute] = SessionsHomeView.initialPath()
    @State private var ticker: Task<Void, Never>?
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var attaching: String?
    @State private var killing: String?
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    private static let macSession = TerminalSessionList.mac

    private var vmSessions: [String] {
        TerminalSessionList.normalized(sessionsRaw)
    }

    private var allSessions: [String] {
        TerminalSessionList.homeList(sessionsRaw)
    }

    private var visibleSessions: [String] {
        SessionsHomeDisplay.rows(allSessions, agents: model.agents)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    herdrCard
                    garimeCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 96)
            }
            .dockScrollTracking()
            .background(Color.paperCanvas.ignoresSafeArea())
            .refreshable { await refreshAll() }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .navigationBarHidden(true)
            .navigationDestination(for: SessionsHomeRoute.self) { route in
                switch route {
                case .session(let name):
                    TerminalScreen(initialSession: name) {
                        if !path.isEmpty { path.removeLast() }
                    }
                case .chat(let target):
                    AgentChatView(target: target) {
                        if !path.isEmpty { path.removeLast() }
                    }
                case .garime(let prefill):
                    AgentChatView(target: GarimeAgent.target(agentSession), initialDraft: prefill) {
                        if !path.isEmpty { path.removeLast() }
                    }
                }
            }
        }
        .tint(Color.primary)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("Renomear sessão", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("nome", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancelar", role: .cancel) { renaming = nil }
            Button("Renomear") { confirmRename() }
        }
        .confirmationDialog(
            "Matar \(TerminalSessionList.label(for: killing ?? ""))?",
            isPresented: Binding(get: { killing != nil }, set: { if !$0 { killing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Matar sessão", role: .destructive) { confirmKill() }
            Button("Cancelar", role: .cancel) { killing = nil }
        } message: {
            Text("A sessão e o que estiver rodando nela morrem. Não dá pra desfazer.")
        }
        .alert(
            renameError ?? "",
            isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })
        ) {
            Button("Ok", role: .cancel) { renameError = nil }
        }
        .task {
            await refreshAll()
            openDebugHerdr()
        }
        .onAppear { startTicker() }
        .onDisappear { stopTicker() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startTicker()
                Task { await refreshAll() }
            } else {
                stopTicker()
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 1), value: sessionsRaw)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.herdr)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.agents)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: attaching)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Agente")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.primary)
            Spacer()
            HStack(spacing: 0) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Atualizar")
                .accessibilityIdentifier("agent-refresh")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Ajustes")
                .accessibilityIdentifier("agent-settings")
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 4)
            .background(Color.paperCard, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(Color.paperCanvas)
    }

    // MARK: - Cartões

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous)
                        .fill(Color.paperCard)
                )
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 16)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }

    private func dot(_ on: Bool) -> some View {
        Circle()
            .fill(on ? Color.primary : Color.secondary.opacity(0.28))
            .frame(width: 8, height: 8)
    }

    private func rowBody(on: Bool, title: String, note: String?, busy: Bool) -> some View {
        HStack(spacing: 12) {
            if busy {
                ProgressView().controlSize(.mini).frame(width: 8)
            } else {
                dot(on)
            }
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            if let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    // MARK: - Herdr

    @ViewBuilder
    private var herdrCard: some View {
        card("Herdr") {
            if !model.herdrLoaded {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Procurando sessões…")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            } else if !model.herdrMacOnline {
                line("Mac offline")
            } else if model.herdr.isEmpty {
                line("Nenhuma sessão no herdr")
            } else {
                ForEach(Array(model.herdr.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { rowDivider }
                    Button { attachHerdr(session.name) } label: {
                        rowBody(
                            on: session.running,
                            title: session.name,
                            note: session.note,
                            busy: attaching == Self.herdrKey(session.name)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("herdr-\(session.name)")
                    .accessibilityHint("abre a sessão do herdr no terminal")
                }
            }
        }
    }

    // MARK: - Terminais

    @ViewBuilder
    private var terminalsCard: some View {
        card("Terminais") {
            ForEach(Array(visibleSessions.enumerated()), id: \.element) { index, name in
                if index > 0 { rowDivider }
                sessionRow(name)
            }
            ForEach(TermAgentOrder.sorted(model.agents)) { agent in
                rowDivider
                agentRow(agent)
            }
            rowDivider
            Button { create() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 8)
                    Text("Nova sessão")
                        .font(.system(size: 16))
                    Spacer(minLength: 4)
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("terminal-new")
        }
    }

    private func sessionRow(_ name: String) -> some View {
        let dead = model.isDead(name)
        return Button { path.append(.session(name)) } label: {
            rowBody(
                on: !dead,
                title: TerminalSessionList.label(for: name),
                note: TerminalSessionList.origin(for: name) == "mac" ? "Mac" : nil,
                busy: false
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("abre o terminal")
        .contextMenu {
            if SessionsHomeStart.startable(session: name) {
                Menu {
                    ForEach(SessionsHomeStart.agents, id: \.self) { agent in
                        Button { startAgent(name, agent: agent) } label: {
                            Label(agent, systemImage: AgentMark.symbol(for: agent) ?? "sparkle")
                        }
                    }
                } label: {
                    Label("Iniciar agente", systemImage: "play")
                }
            }
            if name != Self.macSession {
                Button { startRename(name) } label: {
                    Label("Renomear", systemImage: "pencil")
                }
            }
            if SessionsHomeKill.killable(session: name) {
                Button(role: .destructive) { killing = name } label: {
                    Label("Matar sessão", systemImage: "xmark")
                }
            }
        }
    }

    @ViewBuilder
    private func agentRow(_ agent: TermAgentProcess) -> some View {
        let detail = [agent.project, agent.title].filter { !$0.isEmpty }.joined(separator: " · ")
        if let target = AgentChatTarget(agent) {
            Button { path.append(.chat(target)) } label: {
                rowBody(on: agent.isBusy, title: agent.agent, note: detail, busy: attaching == agent.id)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if agent.isAttachable {
                    Button { attachAgent(agent) } label: {
                        Label("Abrir no terminal", systemImage: "terminal")
                    }
                } else if !agent.session.isEmpty {
                    Button { path.append(.session("vm:\(agent.session)")) } label: {
                        Label("Abrir no terminal", systemImage: "terminal")
                    }
                }
                if let target = SessionsHomeKill.target(agent) {
                    Button(role: .destructive) { killing = target } label: {
                        Label("Matar sessão", systemImage: "xmark")
                    }
                }
            }
        } else {
            rowBody(on: agent.isBusy, title: agent.agent, note: detail, busy: false)
        }
    }

    // MARK: - Garime

    private var garimeCard: some View {
        card("Garime") {
            Button { path.append(.garime(prefill: "")) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Conversar com o Garime")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text("Pergunte, acompanhe e responda quando ele precisar de você.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("garime-chat")
            rowDivider
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AgentQuickPrompt.all, id: \.self) { prompt in
                        Button { path.append(.garime(prefill: prompt.text)) } label: {
                            Text(prompt.label)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.primary)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous)
                                        .fill(Color.paperTile)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Ações

    private func refreshAll(force: Bool = true) async {
        await model.refresh(force: force)
        let known = Set(vmSessions)
        let extras = model.serverSessions
            .filter { $0 != "mac" }
            .map { "vm:\($0)" }
            .filter { !known.contains($0) }
        guard !extras.isEmpty else { return }
        sessionsRaw = (vmSessions + extras).joined(separator: ",")
        await model.refresh(force: force)
    }

    private func create() {
        let existing = Set(vmSessions)
        var name = "vm:mobile"
        var index = 2
        while existing.contains(name) || name == TerminalSessionList.reserved {
            name = "vm:mobile\(index)"
            index += 1
        }
        sessionsRaw = (vmSessions + [name]).joined(separator: ",")
        path.append(.session(name))
    }

    private func attachAgent(_ agent: TermAgentProcess) {
        guard agent.isAttachable, attaching == nil else { return }
        attaching = agent.id
        Task {
            let session = await model.attachAgent(project: agent.project, pane: agent.pane)
            attaching = nil
            guard let session else {
                await presentRenameError("falha ao abrir agente")
                return
            }
            path.append(.session("vm:\(session)"))
        }
    }

    private func attachHerdr(_ project: String) {
        guard !project.isEmpty, attaching == nil else { return }
        attaching = Self.herdrKey(project)
        Task {
            let session = await model.attachHerdr(project: project)
            attaching = nil
            guard let session else {
                await presentRenameError("falha ao abrir herdr")
                return
            }
            path.append(.session("vm:\(session)"))
        }
    }

    private static func herdrKey(_ project: String) -> String {
        "herdr|\(project)"
    }

    private func openDebugHerdr() {
        #if DEBUG
        guard let name = Self.debugHerdr(), path.isEmpty else { return }
        attachHerdr(name)
        #endif
    }

    private func startAgent(_ name: String, agent: String) {
        Task {
            guard let outcome = await model.startAgent(name, agent: agent) else { return }
            guard let notice = SessionsHomeStart.notice(outcome) else {
                await refreshAll()
                return
            }
            await presentRenameError(notice)
        }
    }

    private func startRename(_ name: String) {
        renameText = TerminalSessionList.label(for: name)
        renaming = name
    }

    private func confirmRename() {
        guard let name = renaming else { return }
        let to = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        Task {
            guard TerminalSessionList.isValidName(to) else {
                await presentRenameError("nome inválido")
                return
            }
            guard !vmSessions.contains("vm:\(to)") else {
                await presentRenameError("nome já em uso")
                return
            }
            guard await model.rename(name, to: to) else {
                await presentRenameError("falha ao renomear")
                return
            }
            sessionsRaw = TerminalSessionList.renamed(raw: sessionsRaw, from: name, to: to)
            await refreshAll()
        }
    }

    @MainActor
    private func presentRenameError(_ message: String) async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        renameError = message
    }

    private func confirmKill() {
        guard let name = killing else { return }
        killing = nil
        kill(name)
    }

    private func kill(_ name: String) {
        guard SessionsHomeKill.killable(session: name) else { return }
        var list = vmSessions.filter { $0 != name }
        if list.isEmpty { list = ["vm:mobile"] }
        sessionsRaw = list.joined(separator: ",")
        Task {
            await model.kill(name)
            await refreshAll()
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                await refreshAll(force: false)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private static func debugHerdr() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "-geoHerdr"),
              index + 1 < CommandLine.arguments.count
        else { return nil }
        let name = CommandLine.arguments[index + 1]
        return name.isEmpty ? nil : name
    }

    private static func initialPath() -> [SessionsHomeRoute] {
        if let index = CommandLine.arguments.firstIndex(of: "-geoChat"),
           index + 1 < CommandLine.arguments.count {
            let parts = CommandLine.arguments[index + 1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 3, parts[0] == "session" {
                return [.chat(AgentChatTarget(
                    session: parts[1],
                    agent: parts[2],
                    status: parts.count > 3 ? parts[3] : "",
                    title: parts.count > 4 ? parts[4] : ""
                ))]
            }
            if parts.count >= 3 {
                return [.chat(AgentChatTarget(
                    project: parts[0],
                    pane: parts[1],
                    agent: parts[2],
                    status: parts.count > 3 ? parts[3] : "",
                    title: parts.count > 4 ? parts[4] : ""
                ))]
            }
        }
        if CommandLine.arguments.contains("-geoChat") {
            return [.garime(prefill: "")]
        }
        guard let index = CommandLine.arguments.firstIndex(of: "-geoSession"),
              index + 1 < CommandLine.arguments.count
        else { return [] }
        let raw = CommandLine.arguments[index + 1]
        return [.session(raw.contains(":") ? raw : "vm:\(raw)")]
    }
}
