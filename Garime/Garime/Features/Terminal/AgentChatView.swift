import SwiftUI
import UIKit

struct AgentChatTarget: Hashable {
    let project: String
    let pane: String
    let agent: String
    let status: String
    let title: String

    init(project: String, pane: String, agent: String, status: String = "", title: String = "") {
        self.project = project
        self.pane = pane
        self.agent = agent
        self.status = status
        self.title = title
    }

    init(_ process: TermAgentProcess) {
        self.init(
            project: process.project,
            pane: process.pane,
            agent: process.agent,
            status: process.status,
            title: process.title
        )
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

    private struct Raw: Decodable {
        let role: String?
        let text: String?
        let tool: String?
        let ts: String?
        let truncated: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case agent, status, messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = ((try? container.decodeIfPresent(String.self, forKey: .agent)) ?? nil) ?? ""
        status = ((try? container.decodeIfPresent(String.self, forKey: .status)) ?? nil) ?? ""
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
    @Published var errorMessage: String?

    static let limit = 80
    static let workingInterval: UInt64 = 3_000_000_000
    static let restingInterval: UInt64 = 6_000_000_000

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

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let path = BridgeEndpoint.termAgentChat(
            project: target.project,
            pane: target.pane,
            limit: Self.limit
        ).path
        do {
            let data = try await client.getData(path, token: BridgeConfig.termToken)
            let payload = try JSONDecoder().decode(AgentChatPayload.self, from: data)
            server = payload.messages
            status = payload.status
            noAgent = false
            reachable = true
            loaded = true
            reconcile()
        } catch BridgeError.server(let status, _) where status == 404 {
            noAgent = true
            reachable = true
            loaded = true
        } catch {
            reachable = false
        }
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
        let path = BridgeEndpoint.termAgentPrompt(project: target.project, pane: target.pane).path
        do {
            _ = try await client.postData(path, body: Data(draft.text.utf8), token: BridgeConfig.termToken)
        } catch {
            mark(id, failed: true)
            errorMessage = "não enviou — toque para tentar de novo"
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
                .font(.system(size: 12, design: .monospaced))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                marks(active: -1)
            } else {
                TimelineView(.periodic(from: .now, by: 0.3)) { context in
                    marks(active: Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(StatusLevel.working.label)
    }

    private func marks(active: Int) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.slateTextDim)
                        .frame(width: 4, height: 4)
                        .opacity(active < 0 ? 0.55 : (active == index ? 1 : 0.2))
                        .animation(.easeInOut(duration: 0.28), value: active)
                }
            }
            Text(StatusLevel.working.label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct AgentChatView: View {
    let target: AgentChatTarget
    var onBack: () -> Void = {}

    @StateObject private var model: AgentChatModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var ticker: Task<Void, Never>?
    @State private var atBottom = true
    @FocusState private var composerFocused: Bool

    init(target: AgentChatTarget, onBack: @escaping () -> Void = {}) {
        self.target = target
        self.onBack = onBack
        _model = StateObject(wrappedValue: AgentChatModel(target: target))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(AgentChatFeed.items(model.messages)) { item in
                        row(item)
                    }
                    if model.messages.isEmpty {
                        placeholder
                    }
                    if model.isWorking {
                        AgentChatWorkingRow()
                            .transition(.opacity)
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
            .animation(.spring(response: 0.34, dampingFraction: 1), value: model.isWorking)
            .onChange(of: model.messages.count) { _, _ in
                guard atBottom else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .task {
                await model.refresh()
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        .background(Color.slateCanvas.ignoresSafeArea())
        .safeAreaInset(edge: .top) { header }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .alert(
            model.errorMessage ?? "",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("ok", role: .cancel) { model.errorMessage = nil }
        }
        .onAppear { startTicker() }
        .onDisappear { stopTicker() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startTicker()
                Task { await model.refresh() }
            } else {
                stopTicker()
            }
        }
    }

    private static let bottomAnchor = "agent-chat-bottom"

    private var header: some View {
        GlassChrome {
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
                StatusDot(level: model.reachable ? .agent(status: model.status) : .failed)
                    .padding(.trailing, 14)
            }
            .foregroundStyle(.primary)
            .padding(.leading, 2)
            .frame(minHeight: 48)
            .glassSurface(shape: Capsule())
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.reachable)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.status)
    }

    private var subtitle: String {
        let title = target.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return title }
        return target.project
    }

    @ViewBuilder
    private var placeholder: some View {
        Text(AgentChatEmpty.text(loaded: model.loaded, reachable: model.reachable, noAgent: model.noAgent))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.slateTextFaint)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 28)
    }

    @ViewBuilder
    private func row(_ item: AgentChatItem) -> some View {
        switch item {
        case .message(let message):
            if message.role == .user {
                userRow(message)
            } else {
                assistantRow(message)
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
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.slateTextDim)
                if message.failed {
                    Button { Task { await model.retry(message.id) } } label: {
                        Label("não enviou", systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.red)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if message.optimistic {
                    Text("enviando…")
                        .font(.system(size: 10, design: .monospaced))
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
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            prose(message.text, onGlass: false)
            if message.truncated {
                Text("cortado")
                    .font(.system(size: 9, design: .monospaced))
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
            ForEach(Array(AgentChatMarkup.chunks(text).enumerated()), id: \.offset) { _, chunk in
                switch chunk {
                case .prose(let value):
                    Text(AgentChatMarkup.attributed(value))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let value):
                    AgentChatCodeBlock(code: value, onGlass: onGlass)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .font(.system(size: 9, design: .monospaced))
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
            HStack(alignment: .bottom, spacing: 8) {
                TextField("mensagem", text: $draft, axis: .vertical)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.leading, 14)
                    .padding(.vertical, 12)
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
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.sending
    }

    private func submit() {
        let text = draft
        guard canSend else { return }
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
                await model.refresh()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
