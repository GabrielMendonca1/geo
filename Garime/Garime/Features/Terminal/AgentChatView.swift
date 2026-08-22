import PhotosUI
import SwiftUI
import UIKit

struct AgentChatTarget: Hashable {
    let ref: AgentTargetRef
    let project: String
    let agent: String
    let status: String
    let title: String

    init(ref: AgentTargetRef, project: String, agent: String, status: String = "", title: String = "") {
        self.ref = ref
        self.project = project
        self.agent = agent
        self.status = status
        self.title = title
    }

    init(project: String, pane: String, agent: String, status: String = "", title: String = "") {
        self.init(
            ref: .pane(project: project, pane: pane),
            project: project,
            agent: agent,
            status: status,
            title: title
        )
    }

    init(session: String, agent: String, status: String = "", title: String = "") {
        self.init(ref: .session(session), project: "", agent: agent, status: status, title: title)
    }

    init?(_ process: TermAgentProcess) {
        guard let ref = process.chatRef else { return nil }
        self.init(
            ref: ref,
            project: process.project,
            agent: process.agent,
            status: process.status,
            title: process.title
        )
    }
}

enum AgentPromptFailure {
    static func text(_ error: Error) -> String {
        guard case BridgeError.server(let status, _) = error else {
            return "não enviou — toque para tentar de novo"
        }
        switch status {
        case 400: return "texto com caractere inválido"
        case 404: return "agente sumiu da sessão"
        case 503: return "host fora do ar"
        default: return "não enviou — toque para tentar de novo"
        }
    }
}

enum AgentChatRole: String {
    case user
    case assistant
    case tool
}

struct AgentChatMessage: Identifiable, Equatable {
    let id: String
    let role: AgentChatRole
    let text: String
    let tool: String
    let truncated: Bool
    var ts: String = ""
    var failed: Bool = false
    var optimistic: Bool = false
}

struct AgentChatPayload: Decodable {
    let agent: String
    let status: String
    let messages: [AgentChatMessage]
    var hasMore: Bool = false

    private struct Raw: Decodable {
        let role: String?
        let text: String?
        let tool: String?
        let ts: String?
        let truncated: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case agent, status, messages, hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = ((try? container.decodeIfPresent(String.self, forKey: .agent)) ?? nil) ?? ""
        status = ((try? container.decodeIfPresent(String.self, forKey: .status)) ?? nil) ?? ""
        hasMore = ((try? container.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? nil) ?? false
        let raw = ((try? container.decodeIfPresent([Raw].self, forKey: .messages)) ?? nil) ?? []
        messages = raw.enumerated().compactMap { index, item in
            guard let name = item.role, let role = AgentChatRole(rawValue: name) else { return nil }
            let text = item.text ?? ""
            let tool = item.tool ?? ""
            if role == .tool && tool.isEmpty { return nil }
            if role != .tool && text.isEmpty { return nil }
            return AgentChatMessage(
                id: "\(index)|\(item.ts ?? "")|\(name)|\(role == .tool ? tool : String(text.prefix(24)))",
                role: role,
                text: text,
                tool: tool,
                truncated: item.truncated ?? false,
                ts: item.ts ?? ""
            )
        }
    }
}

struct AgentAskOption: Decodable, Identifiable, Equatable {
    let index: Int
    let label: String
    let selected: Bool

    var id: Int { index }

    init(index: Int, label: String, selected: Bool) {
        self.index = index
        self.label = label
        self.selected = selected
    }

    enum CodingKeys: String, CodingKey {
        case index, label, selected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = ((try? container.decodeIfPresent(Int.self, forKey: .index)) ?? nil) ?? -1
        label = (((try? container.decodeIfPresent(String.self, forKey: .label)) ?? nil) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        selected = ((try? container.decodeIfPresent(Bool.self, forKey: .selected)) ?? nil) ?? false
    }
}

struct AgentAskPayload: Decodable, Equatable {
    static let answerableMax = 9

    let asking: Bool
    let kind: String
    let question: String
    let options: [AgentAskOption]
    let rawHint: String
    let truncated: Bool

    static let none = AgentAskPayload(asking: false, kind: "", question: "", options: [], rawHint: "")

    init(asking: Bool, kind: String, question: String, options: [AgentAskOption], rawHint: String) {
        let answerable = options.filter { $0.index <= AgentAskPayload.answerableMax }
        self.asking = asking
        self.kind = kind
        self.question = question
        self.options = answerable
        self.rawHint = rawHint
        self.truncated = answerable.count != options.count
    }

    enum CodingKeys: String, CodingKey {
        case asking, kind, question, options
        case rawHint = "raw_hint"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asking = ((try? container.decodeIfPresent(Bool.self, forKey: .asking)) ?? nil) ?? false
        kind = ((try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil) ?? ""
        question = ((try? container.decodeIfPresent(String.self, forKey: .question)) ?? nil) ?? ""
        rawHint = ((try? container.decodeIfPresent(String.self, forKey: .rawHint)) ?? nil) ?? ""
        var seen = Set<Int>()
        let decoded = (((try? container.decodeIfPresent([AgentAskOption].self, forKey: .options)) ?? nil) ?? [])
            .filter { $0.index >= 0 && !$0.label.isEmpty && seen.insert($0.index).inserted }
        options = decoded.filter { $0.index <= AgentAskPayload.answerableMax }
        truncated = options.count != decoded.count
    }

    var showsCard: Bool { asking && !options.isEmpty }

    var prompt: String { question.isEmpty ? rawHint : question }

    var title: String { kind.isEmpty ? "aguardando resposta" : kind }
}

enum AgentAskDisplay {
    static func session(_ target: AgentTargetRef) -> String? {
        guard case .session(let name) = target else { return nil }
        return name
    }

    static func shows(_ payload: AgentAskPayload, target: AgentTargetRef) -> Bool {
        session(target) != nil && payload.showsCard
    }

    static func canInterrupt(working: Bool, target: AgentTargetRef) -> Bool {
        session(target) != nil && working
    }
}

enum AgentChatItem: Identifiable {
    case message(AgentChatMessage)
    case tools(id: String, names: [String])
    case stamp(id: String, ts: String)

    var id: String {
        switch self {
        case .message(let message): return message.id
        case .tools(let id, _): return "tools|\(id)"
        case .stamp(let id, _): return "stamp|\(id)"
        }
    }
}

enum AgentChatFeed {
    static func items(_ messages: [AgentChatMessage]) -> [AgentChatItem] {
        var items: [AgentChatItem] = []
        var lastStamp: Date?
        for message in messages {
            guard message.role == .tool else {
                if let date = AgentChatClock.date(message.ts) {
                    if lastStamp == nil || date.timeIntervalSince(lastStamp!) >= AgentChatClock.gap {
                        items.append(.stamp(id: message.id, ts: message.ts))
                    }
                    lastStamp = date
                }
                items.append(.message(message))
                continue
            }
            if case .tools(let id, let names) = items.last {
                items[items.count - 1] = .tools(id: id, names: names + [message.tool])
            } else {
                items.append(.tools(id: message.id, names: [message.tool]))
            }
        }
        return items
    }

    static func symbol(for tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "terminal": return "terminal"
        case "read", "notebookedit": return "doc.text"
        case "write", "edit", "multiedit": return "pencil"
        case "grep", "glob", "search": return "magnifyingglass"
        case "task", "agent": return "square.stack.3d.up"
        case "webfetch", "websearch": return "globe"
        case "todowrite": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }
}

@MainActor
final class AgentChatModel: ObservableObject {
    @Published private(set) var messages: [AgentChatMessage] = []
    @Published private(set) var status = ""
    @Published private(set) var reachable = true
    @Published private(set) var loaded = false
    @Published private(set) var noAgent = false
    @Published private(set) var sending = false
    @Published private(set) var work = AgentWorkPayload.none
    @Published private(set) var ask = AgentAskPayload.none
    @Published private(set) var answering: Int?
    @Published private(set) var interrupting = false
    @Published private(set) var notice = ""
    @Published var errorMessage: String?

    static let limit = 80
    static let workingInterval: UInt64 = 3_000_000_000
    static let restingInterval: UInt64 = 3_000_000_000

    private struct Draft {
        let id: String
        let text: String
        let baseline: Int
    }

    private let client: any BridgeAPI
    private let target: AgentChatTarget
    private var server: [AgentChatMessage] = []
    private var drafts: [Draft] = []
    private var refreshing = false
    private var askSeq = 0
    @Published private(set) var streamConnected = false
    @Published private(set) var hasMore = false
    @Published private(set) var loadingOlder = false
    private var skipCount = 0
    private var streamTask: Task<Void, Never>?
    private var lastStreamStatus = ""
    private var lastStreamCount = -1

    init(target: AgentChatTarget, client: any BridgeAPI = BridgeClient.shared) {
        self.target = target
        self.client = client
        status = target.status
    }

    var isWorking: Bool {
        status == "working" || status == "running"
    }

    var pollInterval: UInt64 {
        isWorking ? Self.workingInterval : Self.restingInterval
    }

    var showsAskCard: Bool {
        AgentAskDisplay.shows(ask, target: target.ref)
    }

    var canInterrupt: Bool {
        AgentAskDisplay.canInterrupt(working: isWorking, target: target.ref)
    }

    var feedKey: String {
        let asking = showsAskCard ? "1" : "0"
        guard let last = messages.last else { return "0|\(asking)" }
        return "\(messages.count)|\(last.id)|\(last.text.count)|\(asking)"
    }

    func apply(_ payload: AgentChatPayload) async {
        if !loadingOlder {
            skipCount = 0
            hasMore = false
        }
        server = payload.messages
        status = payload.status
        noAgent = false
        reachable = true
        loaded = true
        reconcile()
        if payload.status != lastStreamStatus || payload.messages.count != lastStreamCount {
            lastStreamStatus = payload.status
            lastStreamCount = payload.messages.count
            await refreshWork()
            await refreshAsk()
        }
    }

    func loadOlder() async {
        guard !loadingOlder, !server.isEmpty else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        let before = skipCount + server.count
        let path = BridgeEndpoint.termAgentChat(target: target.ref, limit: Self.limit).path + "&before=\(before)"
        do {
            let data = try await client.getData(path, token: BridgeConfig.termToken)
            let payload = try JSONDecoder().decode(AgentChatPayload.self, from: data)
            guard !payload.messages.isEmpty else {
                hasMore = false
                return
            }
            skipCount = before
            hasMore = payload.hasMore
            let known = Set(server.map(\.id))
            server = payload.messages.filter { !known.contains($0.id) } + server
            reconcile()
        } catch {
            reachable = false
        }
    }

    func startStream() {
        guard streamTask == nil, case .session(let name) = target.ref else { return }
        streamTask = Task {
            var backoff: UInt64 = 2_000_000_000
            while !Task.isCancelled {
                do {
                    var req = URLRequest(url: URL(string: BridgeConfig.baseURLString + "/term/agent-stream?session=\(name)&limit=\(Self.limit)")!)
                    req.setValue("Bearer \(BridgeConfig.termToken ?? "")", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = 330
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    backoff = 2_000_000_000
                    await MainActor.run { streamConnected = true }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        if let payload = try? JSONDecoder().decode(AgentChatPayload.self, from: Data(line.dropFirst(6).utf8)) {
                            await self.apply(payload)
                        }
                    }
                } catch { }
                guard !Task.isCancelled else { break }
                await MainActor.run { streamConnected = false }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 30_000_000_000)
            }
        }
    }

    func stopStream() {
        streamTask?.cancel()
        streamTask = nil
        streamConnected = false
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let path = BridgeEndpoint.termAgentChat(target: target.ref, limit: Self.limit).path
        do {
            let data = try await client.getData(path, token: BridgeConfig.termToken)
            let payload = try JSONDecoder().decode(AgentChatPayload.self, from: data)
            server = payload.messages
            status = payload.status
            noAgent = false
            reachable = true
            loaded = true
            reconcile()
            await refreshWork()
            await refreshAsk()
        } catch BridgeError.server(let status, _) where status == 404 {
            noAgent = true
            reachable = true
            loaded = true
            work = .none
            ask = .none
        } catch {
            reachable = false
        }
    }

    private func refreshWork() async {
        let path = BridgeEndpoint.termAgentWork(target: target.ref).path
        guard let data = try? await client.getData(path, token: BridgeConfig.termToken),
              let payload = try? JSONDecoder().decode(AgentWorkPayload.self, from: data)
        else { return }
        work = payload
    }

    private func refreshAsk() async {
        guard answering == nil else { return }
        let seq = askSeq
        let path = BridgeEndpoint.termAgentAsk(target: target.ref).path
        guard let data = try? await client.getData(path, token: BridgeConfig.termToken),
              let payload = try? JSONDecoder().decode(AgentAskPayload.self, from: data)
        else {
            if seq == askSeq { ask = .none }
            return
        }
        guard seq == askSeq else { return }
        ask = payload
    }

    func answer(_ index: Int) async {
        guard answering == nil, let session = AgentAskDisplay.session(target.ref) else { return }
        answering = index
        askSeq += 1
        notice = ""
        let path = BridgeEndpoint.termAgentAnswer(session: session).path
        let body = Data(#"{"index":\#(index)}"#.utf8)
        do {
            _ = try await client.postData(path, body: body, token: BridgeConfig.termToken)
        } catch BridgeError.server(let status, let code) where status == 409 {
            answering = nil
            askSeq += 1
            if code == "not_asking" {
                ask = .none
                notice = "a pergunta expirou"
            } else {
                notice = "não deu pra entregar a resposta"
            }
            return
        } catch {
            answering = nil
            askSeq += 1
            notice = "não deu pra responder"
            return
        }
        ask = .none
        answering = nil
        askSeq += 1
        await refresh()
    }

    func interrupt() async {
        guard !interrupting, let session = AgentAskDisplay.session(target.ref) else { return }
        interrupting = true
        defer { interrupting = false }
        let path = BridgeEndpoint.termAgentInterrupt(session: session).path
        do {
            _ = try await client.postData(path, body: nil, token: BridgeConfig.termToken)
            notice = "interrupção enviada"
        } catch {
            notice = "não deu pra interromper"
        }
    }

    func clearNotice() {
        notice = ""
    }

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        let draft = Draft(id: UUID().uuidString, text: text, baseline: server.count)
        drafts.append(draft)
        rebuild()
        await deliver(draft.id)
    }

    func retry(_ id: String) async {
        guard !sending else { return }
        await deliver(id)
    }

    func discard(_ id: String) {
        drafts.removeAll { $0.id == id }
        rebuild()
    }

    private func deliver(_ id: String) async {
        guard let draft = drafts.first(where: { $0.id == id }) else { return }
        sending = true
        defer { sending = false }
        mark(id, failed: false)
        let path = BridgeEndpoint.termAgentPrompt(target: target.ref).path
        do {
            _ = try await client.postData(path, body: Data(draft.text.utf8), token: BridgeConfig.termToken)
        } catch {
            mark(id, failed: true)
            errorMessage = AgentPromptFailure.text(error)
            return
        }
        await refresh()
    }

    private func mark(_ id: String, failed: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].failed = failed
    }

    private func reconcile() {
        for draft in drafts {
            let start = min(draft.baseline, server.count)
            let matched = server[start...].contains { $0.role == .user && $0.text == draft.text }
            if matched {
                drafts.removeAll { $0.id == draft.id }
            }
        }
        rebuild()
    }

    private func rebuild() {
        let failedIDs = Set(messages.filter(\.failed).map(\.id))
        messages = server + drafts.map {
            AgentChatMessage(
                id: $0.id,
                role: .user,
                text: $0.text,
                tool: "",
                truncated: false,
                failed: failedIDs.contains($0.id),
                optimistic: true
            )
        }
    }
}

struct AgentChatCodeBlock: View {
    let code: String
    var onGlass = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface)
        .clipShape(shape)
        .overlay(shape.stroke(Color.slateStroke.opacity(onGlass ? 0.3 : 0.18), lineWidth: 0.5))
    }

    @ViewBuilder
    private var surface: some View {
        if onGlass {
            shape.fill(Color.slateInk(0.07))
        } else {
            Color.clear.glassSurface(shape: shape)
        }
    }
}

struct AgentChatWorkingRow: View {
    var body: some View {
        HStack(spacing: 6) {
            AgentPulseMarks()
            Text("escrevendo…")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement()
        .accessibilityLabel(StatusLevel.working.label)
    }
}

struct AgentChatView: View {
    let target: AgentChatTarget
    var initialDraft: String = ""
    var onBack: () -> Void = {}

    @StateObject private var model: AgentChatModel
    @StateObject private var composerModel: AgentComposerModel
    @StateObject private var dictation = AgentDictationModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var dock: DockState
    @State private var showCamera = false
    @State private var draft = AgentChatView.initialDraft()
    @State private var ticker: Task<Void, Never>?
    @State private var settle: Task<Void, Never>?
    @State private var atBottom = true
    @State private var pendingNew = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var dictationBase = ""
    @State private var workExpanded = false
    @FocusState private var composerFocused: Bool
    @AppStorage("chat.mode") private var chatModeRaw = ""


    init(target: AgentChatTarget, initialDraft: String = "", onBack: @escaping () -> Void = {}) {
        self.target = target
        self.initialDraft = initialDraft
        self.onBack = onBack
        _model = StateObject(wrappedValue: AgentChatModel(target: target))
        _composerModel = StateObject(wrappedValue: AgentComposerModel(target: target))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.hasMore {
                        Button {
                            let anchor = AgentChatFeed.items(model.messages).first?.id
                            Task {
                                await model.loadOlder()
                                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if model.loadingOlder {
                                    ProgressView().controlSize(.small)
                                }
                                Text("carregar mais antigas")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(Color.slateTextDim)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.loadingOlder)
                    }
                    ForEach(AgentChatFeed.items(model.messages)) { item in
                        row(item)
                            .transition(.opacity)
                    }
                    if model.messages.isEmpty {
                        placeholder
                    }
                    if model.isWorking {
                        AgentChatWorkingRow()
                            .transition(.opacity)
                    }
                    if model.showsAskCard {
                        askCard
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .animation(enter, value: model.isWorking)
            .animation(enter, value: model.ask)
            .animation(enter, value: model.messages.count)
            .onChange(of: model.feedKey) { _, _ in
                guard atBottom else {
                    pendingNew = true
                    return
                }
                glideToBottom(proxy)
            }
            .onChange(of: atBottom) { _, value in
                if value { pendingNew = false }
            }
            .onChange(of: composerFocused) { _, focused in
                if focused { glideToBottom(proxy) }
            }
            .overlay(alignment: .bottom) {
                if pendingNew {
                    newMessagesPill {
                        pendingNew = false
                        glideToBottom(proxy)
                    }
                }
            }
            .animation(enter, value: pendingNew)
            .overlay(alignment: .top) { topScrim }
            .safeAreaInset(edge: .top) { header }
            .safeAreaInset(edge: .bottom) { composer }
            .task {
                await model.refresh()
                model.startStream()
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        .background(Color.slateCanvas.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .alert(
            model.errorMessage ?? "",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("ok", role: .cancel) { model.errorMessage = nil }
        }
        .task(id: model.notice) {
            guard !model.notice.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            model.clearNotice()
        }
        .onAppear {
            dock.hidden = true
            startTicker()
            if draft.isEmpty, !initialDraft.isEmpty {
                draft = initialDraft
            }
        }
        .onDisappear {
            dock.hidden = false
            model.stopStream()
            stopTicker()
            settle?.cancel()
            dictation.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startTicker()
                Task { await model.refresh() }
            } else {
                model.stopStream()
                stopTicker()
                dictation.stop()
            }
        }
    }

    private static let bottomAnchor = "agent-chat-bottom"
    private static let scrimFade: CGFloat = 16

    private var enter: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)
    }

    private func glideToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(enter) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(enter) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private func newMessagesPill(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("novas mensagens")
                    .font(.footnote)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassSurface(shape: Capsule(), interactive: true)
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    private var askCard: some View {
        let shape = RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .font(.footnote.weight(.semibold))
                    Text(model.ask.title)
                        .font(.footnote.weight(.medium))
                        .monospaced()
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.slateTextDim)
                if !model.ask.prompt.isEmpty {
                    prose(model.ask.prompt, onGlass: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model.ask.title). \(model.ask.prompt)")
            .accessibilityAddTraits(.isHeader)
            if model.ask.truncated {
                Text("só as \(AgentAskPayload.answerableMax) primeiras dá pra responder aqui — o resto, pelo terminal")
                    .font(.footnote.weight(.medium))
                    .monospaced()
                    .foregroundStyle(Color.slateTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(Array(model.ask.options.enumerated()), id: \.element.id) { position, option in
                    askButton(option, position: position + 1, total: model.ask.options.count)
                }
            }
        }
        .padding(12)
        .glassSurface(shape: shape)
        .overlay(shape.stroke(Color.slateStroke.opacity(0.8), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("pergunta do agente")
        .transition(.opacity)
    }

    private func askButton(_ option: AgentAskOption, position: Int, total: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous)
        let busy = model.answering == option.index
        return Button { Task { await model.answer(option.index) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(option.label)
                    .font(.callout.weight(option.selected ? .semibold : .regular))
                    .monospaced()
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if busy {
                    ProgressView().controlSize(.mini)
                } else if option.selected {
                    Image(systemName: "return")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.slateTextDim)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(shape.fill(Color.slateInk(option.selected ? 0.16 : 0.07)))
            .overlay(shape.stroke(Color.slateStroke.opacity(option.selected ? 0.9 : 0.35), lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(model.answering != nil)
        .opacity(model.answering == nil || busy ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("opção \(position) de \(total): \(option.label)")
        .accessibilityValue(busy ? "enviando" : (option.selected ? "sugerida" : ""))
        .accessibilityHint("responde a pergunta do agente")
        .accessibilityAddTraits(.isButton)
    }

    private var stopButton: some View {
        Button { Task { await model.interrupt() } } label: {
            Group {
                if model.interrupting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.red)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.interrupting)
        .accessibilityLabel("interromper agente")
        .accessibilityValue(model.interrupting ? "enviando" : "")
        .accessibilityHint("para o que o agente está fazendo agora")
    }

    private var topScrim: some View {
        GeometryReader { proxy in
            let top = max(proxy.safeAreaInsets.top, 1)
            LinearGradient(
                stops: [
                    .init(color: Color.slateCanvas, location: 0),
                    .init(color: Color.slateCanvas, location: top / (top + Self.scrimFade)),
                    .init(color: Color.slateCanvas.opacity(0), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: top + Self.scrimFade)
            .offset(y: -top)
        }
        .allowsHitTesting(false)
    }

    private var header: some View {
        GlassChrome {
            VStack(spacing: 4) {
                headerBar
                if model.work.hasWork {
                    AgentWorkBand(work: model.work, expanded: $workExpanded)
                        .padding(.horizontal, 12)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 4)
        }
        .animation(enter, value: model.reachable)
        .animation(enter, value: model.status)
        .animation(enter, value: model.work)
        .animation(enter, value: model.interrupting)
        .animation(enter, value: workExpanded)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Button { onBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            AgentBadge(agent: target.agent)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.agent)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.slateTextDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if model.canInterrupt {
                stopButton
                    .transition(.opacity)
            }
            StatusDot(level: model.reachable ? .agent(status: model.status) : .failed)
                .padding(.trailing, 14)
        }
        .foregroundStyle(.primary)
        .padding(.leading, 2)
        .frame(minHeight: 48)
        .glassSurface(shape: Capsule())
        .padding(.horizontal, 12)
    }

    private var subtitle: String {
        let title = target.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return title }
        if !target.project.isEmpty { return target.project }
        if case .session(let session) = target.ref { return session }
        return ""
    }

    @ViewBuilder
    private var placeholder: some View {
        Text(AgentChatEmpty.text(loaded: model.loaded, reachable: model.reachable, noAgent: model.noAgent))
            .font(.footnote)
            .foregroundStyle(Color.slateTextFaint)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 28)
    }

    @ViewBuilder
    private func row(_ item: AgentChatItem) -> some View {
        switch item {
        case .message(let message):
            if message.optimistic || message.text.isEmpty {
                if message.role == .user { userRow(message) } else { assistantRow(message) }
            } else if message.role == .user {
                userRow(message).contextMenu {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Label("copiar", systemImage: "doc.on.doc")
                    }
                    Button {
                        draft = "explica melhor isso: \"\(String(message.text.prefix(280)))\""
                        composerFocused = true
                    } label: {
                        Label("explicar melhor", systemImage: "questionmark.bubble")
                    }
                    Button {
                        draft = message.text
                        composerFocused = true
                    } label: {
                        Label("reenviar", systemImage: "arrow.uturn.backward")
                    }
                }
            } else {
                assistantRow(message).contextMenu {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Label("copiar", systemImage: "doc.on.doc")
                    }
                    Button {
                        draft = "explica melhor isso: \"\(String(message.text.prefix(280)))\""
                        composerFocused = true
                    } label: {
                        Label("explicar melhor", systemImage: "questionmark.bubble")
                    }
                }
            }
        case .tools(_, let names):
            toolRow(names)
        case .stamp(_, let ts):
            stampRow(ts)
        }
    }

    private func userRow(_ message: AgentChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("você")
                    .font(.footnote.weight(.semibold))
                    .monospaced()
                    .foregroundStyle(Color.slateTextDim)
                if message.failed {
                    Button { Task { await model.retry(message.id) } } label: {
                        Label("não enviou", systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.red)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if message.optimistic {
                    Text("enviando…")
                        .font(.footnote)
                        .foregroundStyle(Color.slateTextFaint)
                }
            }
            prose(message.text, onGlass: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
        .opacity(message.optimistic && !message.failed ? 0.6 : 1)
        .contextMenu { copyActions(message) }
    }

    private func assistantRow(_ message: AgentChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(target.agent)
                .font(.footnote.weight(.semibold))
                .monospaced()
                .foregroundStyle(Color.slateTextDim)
            prose(message.text, onGlass: false)
            if message.truncated {
                Text("cortado")
                    .font(.footnote)
                    .foregroundStyle(Color.slateTextFaint)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu { copyActions(message) }
    }

    @ViewBuilder
    private func prose(_ text: String, onGlass: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(AgentChatMarkup.blocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block, onGlass: onGlass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AgentChatBlock, onGlass: Bool) -> some View {
        switch block {
        case .paragraph(let value):
            bodyText(AgentChatMarkup.attributed(value))
        case .heading(let level, let value):
            let font = Self.headingFont(level)
            Text(AgentChatMarkup.attributed(value, base: font))
                .font(font)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        case .bullet(let value):
            listRow(marker: "•", value: value)
        case .ordered(let marker, let value):
            listRow(marker: marker, value: value)
        case .code(let value):
            AgentChatCodeBlock(code: value, onGlass: onGlass)
        }
    }

    private func bodyText(_ value: AttributedString) -> some View {
        Text(value)
            .font(.body)
            .lineSpacing(3)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listRow(marker: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.body)
                .foregroundStyle(Color.slateTextDim)
            bodyText(AgentChatMarkup.attributed(value))
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.bold()
        case 2: return .headline
        default: return .subheadline.bold()
        }
    }

    @ViewBuilder
    private func copyActions(_ message: AgentChatMessage) -> some View {
        Button { UIPasteboard.general.string = message.text } label: {
            Label("copiar", systemImage: "doc.on.doc")
        }
        let code = AgentChatMarkup.code(in: message.text)
        if !code.isEmpty {
            Button { UIPasteboard.general.string = code } label: {
                Label("copiar código", systemImage: "curlybraces")
            }
        }
    }

    private func stampRow(_ ts: String) -> some View {
        Text(AgentChatClock.label(ts))
            .font(.footnote)
            .foregroundStyle(Color.slateTextFaint)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
    }

    private func toolRow(_ names: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 4) {
                    Image(systemName: AgentChatFeed.symbol(for: name))
                        .font(.system(size: 8, weight: .semibold))
                    Text(name)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.slateTextDim)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.slateInk(0.08), in: Capsule())
                .overlay(Capsule().stroke(Color.slateStroke.opacity(0.5), lineWidth: 0.5))
            }
            Spacer(minLength: 0)
        }
    }

    private var composer: some View {
        GlassChrome {
            VStack(alignment: .leading, spacing: 6) {
                if !model.showsAskCard && !AgentChatMode.all.isEmpty && (composerFocused || !chatModeRaw.isEmpty) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(AgentChatMode.all) { mode in
                                Button {
                                    chatModeRaw = (chatModeRaw == mode.rawValue) ? "" : mode.rawValue
                                } label: {
                                    Text(mode.label)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 10)
                                        .frame(minHeight: 26)
                                        .background(chatModeRaw == mode.rawValue ? Color.accentColor.opacity(0.22) : .clear, in: Capsule())
                                        .overlay(Capsule().strokeBorder(Color.slateStroke.opacity(0.5)))
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .transition(.opacity)
                    .accessibilityLabel("modo de conversa")
                }
                if showsCommandMenu {
                    commandMenu
                }
                if !statusLine.isEmpty {
                    Text(statusLine)
                        .font(.footnote)
                        .monospaced()
                        .foregroundStyle(model.notice.isEmpty ? Color.slateTextDim : Color.slateText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 16)
                        .transition(.opacity)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                HStack(alignment: .bottom, spacing: 0) {
                    attachButton
                    TextField("mensagem", text: $draft, axis: .vertical)
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .padding(.vertical, 12)
                    micButton
                    Button { submit() } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.35)
                }
                .foregroundStyle(.primary)
                .glassSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
                .opacity(model.showsAskCard ? 0.5 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .animation(enter, value: showsCommandMenu)
        .animation(enter, value: menuCommands.count)
        .animation(enter, value: chatModeRaw)
        .animation(enter, value: composerFocused)
        .animation(enter, value: statusLine)
        .animation(enter, value: model.showsAskCard)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { data, ext in
                let name = UploadName.sanitized("foto-\(Self.stamp()).\(ext)", fallback: "foto")
                Task { await deliverUpload(data, filename: name) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            importFile(result)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await importPhoto(item) }
        }
        .onAppear { loadCommandsIfNeeded() }
        .onChange(of: draft) { _, _ in loadCommandsIfNeeded() }
        .onChange(of: dictation.transcript) { _, value in
            guard let merged = DictationDraft.merged(base: dictationBase, transcript: value) else { return }
            draft = merged
        }
    }

    private static func initialDraft() -> String {
        guard let index = CommandLine.arguments.firstIndex(of: "-geoDraft"),
              index + 1 < CommandLine.arguments.count
        else { return "" }
        return CommandLine.arguments[index + 1]
    }

    private func loadCommandsIfNeeded() {
        guard AgentCommandMenu.query(draft) != nil else { return }
        Task { await composerModel.loadCommands() }
    }

    private var menuCommands: [AgentCommand] {
        guard let query = AgentCommandMenu.query(draft) else { return [] }
        return AgentCommandMenu.filter(composerModel.commands, query: query)
    }

    private var showsCommandMenu: Bool {
        guard AgentCommandMenu.query(draft) != nil else { return false }
        return composerModel.loadingCommands || !menuCommands.isEmpty
    }

    private var commandMenu: some View {
        let sections = AgentCommandMenu.split(menuCommands)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if menuCommands.isEmpty {
                    commandsLoadingRow
                }
                if !sections.builtin.isEmpty {
                    Text("do agente")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.slateTextFaint)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                    ForEach(sections.builtin) { command in
                        commandRow(command)
                    }
                    if !sections.rest.isEmpty {
                        Divider()
                            .overlay(Color.slateStroke.opacity(0.4))
                            .padding(.vertical, 4)
                        Text("skills")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.slateTextFaint)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 2)
                    }
                }
                ForEach(sections.rest) { command in
                    commandRow(command)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 220)
        .foregroundStyle(.primary)
        .glassSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var commandsLoadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("buscando comandos…")
                .font(.footnote)
                .monospaced()
                .foregroundStyle(Color.slateTextDim)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("buscando comandos")
    }

    private func commandRow(_ command: AgentCommand) -> some View {
        Button {
            draft = AgentCommandMenu.inserted(command.name)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("/\(command.name)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.slateTextDim)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var attachButton: some View {
        Menu {
            Button { showCamera = true } label: { Label("câmera", systemImage: "camera") }
            Button { showPhotoPicker = true } label: { Label("foto", systemImage: "photo") }
            Button { showFileImporter = true } label: { Label("arquivo", systemImage: "doc") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(composerModel.uploading)
        .opacity(composerModel.uploading ? 0.35 : 1)
    }

    private var micButton: some View {
        Button { toggleDictation() } label: {
            Group {
                if dictation.recording && !reduceMotion {
                    TimelineView(.periodic(from: .now, by: 0.6)) { context in
                        micGlyph
                            .opacity(Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0 ? 1 : 0.35)
                    }
                } else {
                    micGlyph
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.recording ? "parar ditado" : "ditar")
    }

    private var micGlyph: some View {
        Image(systemName: dictation.recording ? "stop.circle" : "mic")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(dictation.recording ? Color.red : Color.primary)
    }

    private var statusLine: String {
        if !model.notice.isEmpty { return model.notice }
        if dictation.recording { return "ouvindo…" }
        if !dictation.notice.isEmpty { return dictation.notice }
        return composerModel.notice
    }

    private func toggleDictation() {
        if dictation.recording {
            dictation.stop()
        } else {
            dictationBase = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            dictation.start()
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            composerModel.fail("não deu pra ler a foto")
            return
        }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        let name = UploadName.sanitized("foto-\(Self.stamp()).\(ext)", fallback: "foto")
        await deliverUpload(data, filename: name)
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            composerModel.fail("não deu pra abrir o arquivo")
            return
        }
        let name = UploadName.sanitized(url.lastPathComponent, fallback: "arquivo-\(Self.stamp())")
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                AgentFileRead.read(url)
            }.value
            switch outcome {
            case .ok(let data):
                await deliverUpload(data, filename: name)
            case .tooLarge:
                composerModel.fail("arquivo grande demais")
            case .failed:
                composerModel.fail("não deu pra ler o arquivo")
            }
        }
    }

    private func deliverUpload(_ data: Data, filename: String) async {
        guard let path = await composerModel.upload(data, filename: filename) else { return }
        let isImage = ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(filename.lowercased().split(separator: ".").last.map(String.init) ?? "")
        let lead = isImage ? "olhe a imagem em " : ""
        let separator = draft.isEmpty || draft.hasSuffix(" ") ? "" : " "
        draft += separator + lead + path + (isImage ? " e me diga o que você vê." : " ")
        composerFocused = true
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.sending
    }

    private func submit() {
        guard canSend else { return }
        let mode = AgentChatMode(rawValue: chatModeRaw)?.directive ?? ""
        let text = mode + draft
        chatModeRaw = ""
        dictation.stop()
        composerModel.clearNotice()
        draft = ""
        atBottom = true
        Task { await model.send(text) }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: model.pollInterval)
                guard !Task.isCancelled else { return }
                if !model.streamConnected {
                    await model.refresh()
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}

enum AgentChatMode: String, CaseIterable, Identifiable {
    static let all: [AgentChatMode] = [.rapido, .pesquisa, .executar]

    case rapido
    case pesquisa
    case executar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rapido: return "rápido"
        case .pesquisa: return "pesquisa"
        case .executar: return "executar"
        }
    }

    var directive: String {
        switch self {
        case .rapido:
            return "[modo rápido] Responda de forma enxuta e direta, sem rodeios.\n\n"
        case .pesquisa:
            return "[modo pesquisa] Pesquise na web antes de responder e cite as fontes.\n\n"
        case .executar:
            return "[modo executar] Execute sem pedir confirmação; só me avise do resultado. Ações destrutivas continuam proibidas.\n\n"
        }
    }
}
