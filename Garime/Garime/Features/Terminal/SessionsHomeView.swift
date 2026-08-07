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
}

struct SessionsHomeView: View {
    @StateObject private var model = SessionsHomeModel()
    @AppStorage("terminal.sessions") private var sessionsRaw = "vm:mobile"
    @State private var path: [SessionsHomeRoute] = SessionsHomeView.initialPath()
    @State private var ticker: Task<Void, Never>?
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var attaching: String?
    @State private var killing: String?
    @State private var layout: [TermAgentGroup] = []
    @State private var expanded: Set<String> = []
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
                VStack(alignment: .leading, spacing: 20) {
                    hostCards
                    inventory
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Color.slateCanvas.ignoresSafeArea())
            .refreshable {
                await refreshAll()
                resetLayout()
            }
            .safeAreaInset(edge: .top) { header }
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
                }
            }
        }
        .alert("renomear sessão", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("nome", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("cancelar", role: .cancel) { renaming = nil }
            Button("renomear") { confirmRename() }
        }
        .confirmationDialog(
            "matar \(TerminalSessionList.label(for: killing ?? ""))?",
            isPresented: Binding(get: { killing != nil }, set: { if !$0 { killing = nil } }),
            titleVisibility: .visible
        ) {
            Button("matar sessão", role: .destructive) { confirmKill() }
            Button("cancelar", role: .cancel) { killing = nil }
        } message: {
            Text("a sessão e o que estiver rodando nela morrem. não dá pra desfazer.")
        }
        .alert(
            renameError ?? "",
            isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })
        ) {
            Button("ok", role: .cancel) { renameError = nil }
        }
        .task {
            await refreshAll()
            resetLayout()
        }
        .onChange(of: model.agents) { _, _ in adoptNewGroups() }
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
        .animation(.spring(response: 0.34, dampingFraction: 1), value: expanded)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: sessionsRaw)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.units)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.agents)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.work)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: attaching)
    }

    private var header: some View {
        GlassChrome {
            HStack(spacing: 8) {
                Text("sessões")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Spacer(minLength: 4)
                connectionDot
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.reachable)
    }

    private var hostCards: some View {
        HStack(spacing: 12) {
            hostCard(host: "vm", verb: "nova sessão") { create() }
            hostCard(host: "mac", verb: "abrir mac") { path.append(.session(Self.macSession)) }
        }
    }

    private func hostCard(host: String, verb: String, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: HostMark.symbol(for: host))
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 10)
                Text(verb)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("no \(HostMark.label(for: host))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.slateTextFaint)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aspectRatio(1, contentMode: .fit)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassSurface(shape: shape, interactive: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(verb)
        .accessibilityHint("abre um terminal no \(HostMark.label(for: host))")
        .accessibilityAddTraits(.isButton)
    }

    private var connectionDot: some View {
        StatusDot(level: .link(model.reachable))
    }

    private var inventory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("instâncias")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.slateTextFaint)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(visibleSessions.enumerated()), id: \.element) { index, name in
                    if index > 0 {
                        Divider().overlay(Color.slateStroke.opacity(0.4))
                    }
                    sessionRow(name)
                }
                let groups = TermAgentOrder.merged(layout: layout, live: model.agents)
                if groups.isEmpty {
                    Divider().overlay(Color.slateStroke.opacity(0.4))
                    emptyAgents
                }
                ForEach(groups) { group in
                    Divider().overlay(Color.slateStroke.opacity(0.4))
                    projectHeader(group)
                    if isExpanded(group) {
                        ForEach(group.agents) { agent in
                            Divider().overlay(Color.slateStroke.opacity(0.4))
                            processRow(agent)
                        }
                    }
                }
                if !model.agents.isEmpty {
                    Text("serviços")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.slateTextFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                }
                ForEach(model.units) { unit in
                    agentRow(name: unit.name, active: unit.active, detail: Self.relative(unit.since))
                    Divider().overlay(Color.slateStroke.opacity(0.4))
                }
                agentRow(name: "host mac", active: model.macOnline, detail: nil)
            }
            .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
        }
    }

    private func sessionRow(_ name: String) -> some View {
        Button { path.append(.session(name)) } label: { sessionRowBody(name) }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("sessão \(TerminalSessionList.label(for: name)) no \(TerminalSessionList.origin(for: name))")
            .accessibilityValue(model.isDead(name) ? StatusLevel.dormant.label : StatusLevel.healthy.label)
            .accessibilityHint("abre o terminal")
            .accessibilityAddTraits(.isButton)
            .contextMenu {
                if SessionsHomeStart.startable(session: name) {
                    Menu {
                        ForEach(SessionsHomeStart.agents, id: \.self) { agent in
                            Button { startAgent(name, agent: agent) } label: {
                                Label(agent, systemImage: AgentMark.symbol(for: agent) ?? "sparkle")
                            }
                        }
                    } label: {
                        Label("iniciar agente", systemImage: "play")
                    }
                }
                if name != Self.macSession {
                    Button { startRename(name) } label: {
                        Label("renomear", systemImage: "pencil")
                    }
                }
                if SessionsHomeKill.killable(session: name) {
                    Button(role: .destructive) { killing = name } label: {
                        Label("matar sessão", systemImage: "xmark")
                    }
                }
            }
    }

    private func sessionRowBody(_ name: String) -> some View {
        let dead = model.isDead(name)
        return HStack(spacing: 10) {
            StatusDot(level: .live(!dead))
            HostBadge(host: TerminalSessionList.origin(for: name))
            Text(TerminalSessionList.label(for: name))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.primary)
                .opacity(dead ? 0.45 : 1)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.slateTextFaint)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var emptyAgents: some View {
        Text(model.reachable ? "nenhum agente rodando" : "sem conexão com o mac")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.slateTextFaint)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func isExpanded(_ group: TermAgentGroup) -> Bool {
        group.project.isEmpty || expanded.contains(group.project)
    }

    @ViewBuilder
    private func projectHeader(_ group: TermAgentGroup) -> some View {
        let open = isExpanded(group)
        HStack(spacing: 6) {
            Button { toggle(group.project) } label: {
                HStack(spacing: 6) {
                    if !open {
                        StatusDot(level: group.level)
                    }
                    Text(group.label)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.slateTextDim)
                        .lineLimit(1)
                    if !open {
                        marks(group)
                    }
                    Spacer(minLength: 4)
                    if !open {
                        Text("\(group.agents.count) agentes")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.slateTextFaint)
                            .layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(group.project.isEmpty)
            if !group.project.isEmpty {
                Button { attachHerdr(group.project) } label: {
                    if attaching == Self.herdrKey(group.project) {
                        ProgressView().controlSize(.mini)
                    } else {
                        tag("herdr")
                    }
                }
                .buttonStyle(.plain)
                Button { toggle(group.project) } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.slateTextFaint)
                        .frame(width: 22, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func marks(_ group: TermAgentGroup) -> some View {
        let (symbols, overflow) = group.marks
        return HStack(spacing: 4) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, mark in
                if mark.count == 1 {
                    Text(mark)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                } else {
                    Image(systemName: mark)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.slateTextFaint)
            }
        }
        .foregroundStyle(Color.slateTextDim)
        .layoutPriority(1)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.slateTextDim)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().stroke(Color.slateStroke, lineWidth: 0.5))
            .layoutPriority(1)
    }

    private func toggle(_ project: String) {
        guard !project.isEmpty else { return }
        if expanded.contains(project) {
            expanded.remove(project)
        } else {
            expanded.insert(project)
        }
    }

    private func resetLayout() {
        let groups = TermAgentOrder.ranked(TermAgentOrder.grouped(model.agents))
        layout = groups
        expanded = TermAgentOrder.autoExpanded(groups)
    }

    private func adoptNewGroups() {
        let fresh = TermAgentOrder.adopting(layout: layout, live: model.agents)
        guard !fresh.isEmpty else { return }
        layout += fresh
        expanded.formUnion(fresh.map(\.project))
    }

    @ViewBuilder
    private func processRow(_ agent: TermAgentProcess) -> some View {
        if let target = AgentChatTarget(agent) {
            Button { path.append(.chat(target)) } label: { processRowBody(agent) }
                .buttonStyle(.plain)
                .contextMenu {
                    if agent.isAttachable {
                        Button { attachAgent(agent) } label: {
                            Label("abrir no terminal", systemImage: "terminal")
                        }
                    } else if !agent.session.isEmpty {
                        Button { path.append(.session("vm:\(agent.session)")) } label: {
                            Label("abrir no terminal", systemImage: "terminal")
                        }
                    }
                    if let target = SessionsHomeKill.target(agent) {
                        Button(role: .destructive) { killing = target } label: {
                            Label("matar sessão", systemImage: "xmark")
                        }
                    }
                }
        } else {
            processRowBody(agent)
        }
    }

    private func processRowBody(_ agent: TermAgentProcess) -> some View {
        HStack(spacing: 10) {
            if attaching == agent.id {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 7)
            } else {
                StatusDot(level: .agent(status: agent.status))
            }
            AgentBadge(agent: agent.agent)
            Text(agent.agent)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.primary)
                .opacity(agent.isBusy ? 1 : 0.55)
                .layoutPriority(1)
            if !agent.place.isEmpty {
                Text(agent.place)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.slateTextDim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(1)
            }
            if !agent.title.isEmpty {
                Text(agent.title)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.slateTextDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let count = model.work[agent.id], count > 0 {
                AgentWorkMark(count: count)
            }
            HostBadge(host: agent.host)
                .layoutPriority(1)
            if agent.isChattable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.slateTextFaint)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .opacity(attaching == agent.id ? 0.55 : 1)
    }

    private func agentRow(name: String, active: Bool, detail: String?) -> some View {
        HStack(spacing: 10) {
            StatusDot(level: .live(active))
            Text(name)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.primary)
                .opacity(active ? 1 : 0.45)
            Spacer(minLength: 4)
            if active, let detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.slateTextFaint)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(active ? StatusLevel.healthy.label : StatusLevel.dormant.label)
    }

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

    private static func relative(_ raw: String) -> String? {
        guard let date = systemdFormatter.date(from: raw) else { return nil }
        return "desde " + relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let systemdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm:ss zzz"
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

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
        guard let index = CommandLine.arguments.firstIndex(of: "-geoSession"),
              index + 1 < CommandLine.arguments.count
        else { return [] }
        let raw = CommandLine.arguments[index + 1]
        return [.session(raw.contains(":") ? raw : "vm:\(raw)")]
    }
}
