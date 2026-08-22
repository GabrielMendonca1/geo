import SwiftUI

enum GarimeAgent {
    static let sessionKey = "agent.session"
    static let advancedKey = "terminal.advanced"
    static let fallbackSession = "garime-agent"
    static let name = "pi"

    static func session(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackSession : trimmed
    }

    static func target(_ raw: String) -> AgentChatTarget {
        AgentChatTarget(session: session(raw), agent: name)
    }
}

struct AgentHealthProcess: Decodable, Equatable {
    let session: String
    let running: Bool
    let agent: String
    let busy: Bool

    enum CodingKeys: String, CodingKey {
        case session, running, agent, busy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = ((try? container.decodeIfPresent(String.self, forKey: .session)) ?? nil) ?? ""
        running = ((try? container.decodeIfPresent(Bool.self, forKey: .running)) ?? nil) ?? false
        agent = ((try? container.decodeIfPresent(String.self, forKey: .agent)) ?? nil) ?? ""
        busy = ((try? container.decodeIfPresent(Bool.self, forKey: .busy)) ?? nil) ?? false
    }
}

struct AgentHealthPayload: Decodable, Equatable {
    let ok: Bool
    let macOnline: Bool
    let agent: AgentHealthProcess?

    enum CodingKeys: String, CodingKey {
        case ok
        case macOnline = "mac_online"
        case agent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = ((try? container.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil) ?? true
        macOnline = ((try? container.decodeIfPresent(Bool.self, forKey: .macOnline)) ?? nil) ?? false
        agent = (try? container.decodeIfPresent(AgentHealthProcess.self, forKey: .agent)) ?? nil
    }
}

@MainActor
final class AgentHomeModel: ObservableObject {
    @Published private(set) var loaded = false
    @Published private(set) var reachable = false
    @Published private(set) var macOnline = false
    @Published private(set) var agentRunning = false
    @Published private(set) var agentBusy = false
    @Published private(set) var latency: Int?

    private let client: any BridgeAPI
    private let clock: @Sendable () -> Double
    private var refreshing = false

    init(
        client: any BridgeAPI = BridgeClient.shared,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.client = client
        self.clock = clock
    }

    var vmLevel: StatusLevel {
        loaded ? .link(reachable) : .dormant
    }

    var macLevel: StatusLevel {
        guard loaded, reachable else { return .dormant }
        return .link(macOnline)
    }

    var agentNote: String {
        if !loaded { return "checando" }
        if !reachable { return "bridge fora do ar" }
        return agentBusy ? "trabalhando" : (agentRunning ? "agente de pé" : "agente parado")
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let started = clock()
        do {
            let data = try await client.getData(BridgeEndpoint.termHealth.path, token: BridgeConfig.termToken)
            let payload = try JSONDecoder().decode(AgentHealthPayload.self, from: data)
            reachable = payload.ok
            macOnline = payload.macOnline
            agentRunning = payload.agent?.running ?? false
            agentBusy = payload.agent?.busy ?? false
            latency = max(0, Int(((clock() - started) * 1000).rounded()))
        } catch {
            reachable = false
            macOnline = false
            agentRunning = false
            agentBusy = false
            latency = nil
        }
        loaded = true
    }
}

enum AgentHomeRoute: Hashable {
    case chat(prefill: String)
}

struct AgentHomeView: View {
    @StateObject private var model = AgentHomeModel()
    @AppStorage(GarimeAgent.sessionKey) private var sessionName = GarimeAgent.fallbackSession
    @AppStorage(GarimeAgent.advancedKey) private var advanced = false
    @State private var path: [AgentHomeRoute] = AgentHomeView.initialPath()
    @State private var ticker: Task<Void, Never>?
    @State private var showSessions = false
    @Environment(\.scenePhase) private var scenePhase

    private static let interval: UInt64 = 10_000_000_000

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusCard
                    chatCard
                    if advanced { sessionsLink }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Color.slateCanvas.ignoresSafeArea())
            .refreshable { await model.refresh() }
            .safeAreaInset(edge: .top) { header }
            .navigationBarHidden(true)
            .navigationDestination(for: AgentHomeRoute.self) { route in
                switch route {
                case .chat(let prefill):
                    AgentChatView(target: GarimeAgent.target(sessionName), initialDraft: prefill) {
                        if !path.isEmpty { path.removeLast() }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showSessions) {
            SessionsHomeView()
        }
        .task {
            await model.refresh()
            startTicker()
        }
        .onDisappear { stopTicker() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startTicker()
                Task { await model.refresh() }
            } else {
                stopTicker()
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.reachable)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.macOnline)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: model.agentRunning)
    }

    private var header: some View {
        GlassChrome {
            HStack(spacing: 8) {
                Text("garime")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Spacer(minLength: 4)
                StatusDot(level: model.vmLevel)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
    }

    private var statusCard: some View {
        VStack(spacing: 0) {
            hostRow(host: "mac", level: model.macLevel, detail: nil)
            Divider().overlay(Color.slateStroke.opacity(0.4))
            hostRow(host: "vm", level: model.vmLevel, detail: latencyText)
        }
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private var latencyText: String? {
        guard model.reachable, let latency = model.latency else { return nil }
        return "\(latency)ms"
    }

    private func hostRow(host: String, level: StatusLevel, detail: String?) -> some View {
        HStack(spacing: 10) {
            StatusDot(level: level)
            Image(systemName: HostMark.symbol(for: host))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.slateTextDim)
                .frame(width: 20)
            Text(HostMark.label(for: host))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.primary)
                .opacity(level == .healthy ? 1 : 0.55)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.slateTextFaint)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HostMark.label(for: host))
        .accessibilityValue(level.label)
    }

    private var chatCard: some View {
        let shape = RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            Button { path.append(.chat(prefill: "")) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    AgentBadge(agent: GarimeAgent.name)
                    Spacer(minLength: 4)
                    StatusDot(level: .live(model.agentRunning))
                }
                Spacer(minLength: 18)
                Text("conversar")
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(model.agentNote)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.slateTextFaint)
                    .lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassSurface(shape: shape, interactive: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("conversar com o agente")
        .accessibilityValue(model.agentNote)
        .accessibilityAddTraits(.isButton)
        }
        quickPrompts
    }

    private var quickPrompts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AgentQuickPrompt.all, id: \.self) { prompt in
                    Button { path.append(.chat(prefill: prompt.text)) } label: {
                        Text(prompt.label)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassSurface(shape: Capsule(), interactive: true)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var sessionsLink: some View {
        Button { showSessions = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.slateTextDim)
                    .frame(width: 20)
                Text("sessões")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.slateTextFaint)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.interval)
                if Task.isCancelled { return }
                await model.refresh()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private static func initialPath() -> [AgentHomeRoute] {
        CommandLine.arguments.contains("-geoChat") ? [.chat(prefill: "")] : []
    }
}

#Preview {
    AgentHomeView()
}

struct AgentQuickPrompt: Hashable {
    let label: String
    let text: String

    static let all = [
        AgentQuickPrompt(label: "último treino", text: "como foi meu último treino?"),
        AgentQuickPrompt(label: "tarefas hoje", text: "quais são minhas tarefas pra hoje?"),
        AgentQuickPrompt(label: "resumo do zap", text: "resuma o que apareceu no meu whatsapp hoje"),
    ]
}
