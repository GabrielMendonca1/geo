import SwiftUI

struct TermPreviewPayload: Decodable {
    let text: String
}

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

    var id: String { "\(host)|\(project)|\(agent)|\(pane)|\(title)" }

    var isBusy: Bool { status == "working" || status == "running" }
    var isIdle: Bool { status == "idle" }
    var isAttachable: Bool { host == "mac" && !pane.isEmpty && !project.isEmpty }

    enum CodingKeys: String, CodingKey {
        case host, agent, status, title, project, cwd, pane
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

    static func showsProjectLabels(_ groups: [TermAgentGroup]) -> Bool {
        groups.contains { !$0.project.isEmpty }
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

enum ANSIText {
    private static let escapes = try? NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]"
    )

    static func stripped(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        let clean = escapes?.stringByReplacingMatches(in: raw, range: range, withTemplate: "") ?? raw
        var lines = clean.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class SessionsHomeModel: ObservableObject {
    @Published private(set) var serverSessions: [String] = []
    @Published private(set) var serverListLoaded = false
    @Published private(set) var previews: [String: String] = [:]
    @Published private(set) var units: [TermAgentUnit] = []
    @Published private(set) var agents: [TermAgentProcess] = []
    @Published private(set) var macOnline = false
    @Published private(set) var reachable = true

    static let previewEveryNCycles = 3

    private let client: any BridgeAPI
    private var refreshing = false
    private var coalesced = false
    private var previewCycle = 0

    init(client: any BridgeAPI = BridgeClient.shared) {
        self.client = client
    }

    func isDead(_ name: String) -> Bool {
        guard serverListLoaded else { return false }
        return !serverSessions.contains(TerminalSessionList.endpoint(for: name))
    }

    func refresh(_ names: [String], force: Bool = true) async {
        guard !refreshing else {
            coalesced = coalesced || force
            return
        }
        refreshing = true
        defer { refreshing = false }
        await cycle(names, force: force)
        if coalesced {
            coalesced = false
            await cycle(names, force: true)
        }
    }

    private func cycle(_ names: [String], force: Bool) async {
        var ok = false
        if let data = try? await client.getData(BridgeEndpoint.termList.path, token: BridgeConfig.termToken),
           let list = try? JSONDecoder().decode(TermSessions.self, from: data).sessions {
            serverSessions = list
            serverListLoaded = true
            ok = true
        }
        if let data = try? await client.getData(BridgeEndpoint.termAgents.path, token: BridgeConfig.termToken),
           let payload = try? JSONDecoder().decode(TermAgentsPayload.self, from: data) {
            units = payload.units
            macOnline = payload.macOnline
            agents = TermAgentOrder.sorted(payload.agents)
            ok = true
        }
        for name in previewTargets(names, force: force) {
            let path = BridgeEndpoint.termPreview(session: TerminalSessionList.endpoint(for: name), lines: 12).path
            guard let data = try? await client.getData(path, token: BridgeConfig.termToken),
                  let payload = try? JSONDecoder().decode(TermPreviewPayload.self, from: data)
            else {
                if isDead(name) { previews[name] = nil }
                continue
            }
            previews[name] = ANSIText.stripped(payload.text)
            ok = true
        }
        reachable = ok
    }

    private func previewTargets(_ names: [String], force: Bool) -> [String] {
        guard !force else { return names }
        let due = previewCycle == 0
        previewCycle = (previewCycle + 1) % Self.previewEveryNCycles
        return due ? names : names.filter { previews[$0] == nil }
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

    private static let macSession = TerminalSessionList.mac

    private var vmSessions: [String] {
        TerminalSessionList.normalized(sessionsRaw)
    }

    private var allSessions: [String] {
        TerminalSessionList.homeList(sessionsRaw)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    grid
                    agents
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Color.slateCanvas.ignoresSafeArea())
            .refreshable { await refreshAll() }
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
        .alert(
            renameError ?? "",
            isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })
        ) {
            Button("ok", role: .cancel) { renameError = nil }
        }
        .task { await refreshAll() }
        .onAppear { startTicker() }
        .onDisappear { stopTicker() }
        .animation(.spring(response: 0.34, dampingFraction: 1), value: sessionsRaw)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.units)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.agents)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: attaching)
    }

    private var header: some View {
        GlassChrome {
            HStack(spacing: 8) {
                Text("sessões")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Spacer(minLength: 4)
                connectionDot
                Button { create() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassSurface(shape: Circle(), interactive: true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.reachable)
    }

    private var connectionDot: some View {
        StatusDot(level: .link(model.reachable))
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            ForEach(allSessions, id: \.self) { name in
                Button { path.append(.session(name)) } label: { card(name) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if name != Self.macSession {
                            Button { startRename(name) } label: {
                                Label("renomear", systemImage: "pencil")
                            }
                            Button(role: .destructive) { kill(name) } label: {
                                Label("matar sessão", systemImage: "xmark")
                            }
                        }
                    }
            }
        }
    }

    private func card(_ name: String) -> some View {
        let dead = model.isDead(name)
        let preview = model.previews[name]
        return VStack(alignment: .leading, spacing: 10) {
            Group {
                if let preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(Color.slateTextDim)
                        .lineSpacing(1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Text(dead ? "toque para conectar" : "sem saída")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.slateTextFaint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(height: 84, alignment: .topLeading)
            .clipped()

            HStack(spacing: 7) {
                StatusDot(level: .live(!dead))
                Text(TerminalSessionList.label(for: name))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .opacity(dead ? 0.45 : 1)
                Spacer(minLength: 4)
                Text(TerminalSessionList.origin(for: name))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.slateTextDim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Capsule().stroke(Color.slateStroke, lineWidth: 0.5))
            }
        }
        .padding(12)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous), interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("agentes")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.slateTextFaint)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                let groups = TermAgentOrder.grouped(model.agents)
                let showsLabels = TermAgentOrder.showsProjectLabels(groups)
                ForEach(groups) { group in
                    if showsLabels {
                        projectHeader(group)
                    }
                    ForEach(group.agents) { agent in
                        processRow(agent)
                        Divider().overlay(Color.slateStroke.opacity(0.4))
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
                agentRow(name: "mac", active: model.macOnline, detail: nil)
            }
            .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
        }
    }

    @ViewBuilder
    private func projectHeader(_ group: TermAgentGroup) -> some View {
        if group.project.isEmpty {
            projectHeaderBody(group, tappable: false)
        } else {
            Button { attachHerdr(group.project) } label: { projectHeaderBody(group, tappable: true) }
                .buttonStyle(.plain)
        }
    }

    private func projectHeaderBody(_ group: TermAgentGroup, tappable: Bool) -> some View {
        HStack(spacing: 5) {
            Text(group.label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.slateTextFaint)
            if tappable {
                if attaching == Self.herdrKey(group.project) {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.slateTextFaint)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44, alignment: .bottomLeading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func processRow(_ agent: TermAgentProcess) -> some View {
        if agent.isAttachable {
            Button { path.append(.chat(AgentChatTarget(agent))) } label: { processRowBody(agent) }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { attachAgent(agent) } label: {
                        Label("abrir no terminal", systemImage: "terminal")
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
            if !agent.title.isEmpty {
                Text(agent.title)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.slateTextDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(agent.host)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(Capsule().stroke(Color.slateStroke, lineWidth: 0.5))
                .layoutPriority(1)
            if agent.isAttachable {
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
    }

    private func refreshAll(force: Bool = true) async {
        await model.refresh(allSessions, force: force)
        let known = Set(vmSessions)
        let extras = model.serverSessions
            .filter { $0 != "mac" }
            .map { "vm:\($0)" }
            .filter { !known.contains($0) }
        guard !extras.isEmpty else { return }
        sessionsRaw = (vmSessions + extras).joined(separator: ",")
        await model.refresh(allSessions, force: force)
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

    private func kill(_ name: String) {
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
