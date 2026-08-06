import SwiftUI

struct AgentWorkflow: Decodable, Identifiable, Equatable {
    let id: String
    let running: Int
    let done: Int
    let since: String

    var total: Int { running + done }

    init(id: String, running: Int, done: Int, since: String) {
        self.id = id
        self.running = running
        self.done = done
        self.since = since
    }

    enum CodingKeys: String, CodingKey {
        case id, running, done, since
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? ""
        running = max(0, ((try? container.decodeIfPresent(Int.self, forKey: .running)) ?? nil) ?? 0)
        done = max(0, ((try? container.decodeIfPresent(Int.self, forKey: .done)) ?? nil) ?? 0)
        since = ((try? container.decodeIfPresent(String.self, forKey: .since)) ?? nil) ?? ""
    }
}

struct AgentSubagent: Decodable, Identifiable, Equatable {
    let id: String
    let type: String
    let running: Bool
    let since: String

    init(id: String, type: String, running: Bool, since: String) {
        self.id = id
        self.type = type
        self.running = running
        self.since = since
    }

    enum CodingKeys: String, CodingKey {
        case id, type, running, since
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? ""
        type = ((try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil) ?? ""
        running = ((try? container.decodeIfPresent(Bool.self, forKey: .running)) ?? nil) ?? false
        since = ((try? container.decodeIfPresent(String.self, forKey: .since)) ?? nil) ?? ""
    }
}

struct AgentWorkPayload: Decodable, Equatable {
    let agent: String
    let supported: Bool
    let workflows: [AgentWorkflow]
    let subagents: [AgentSubagent]
    let truncated: Bool

    static let none = AgentWorkPayload(agent: "", supported: false, workflows: [], subagents: [], truncated: false)

    init(agent: String, supported: Bool, workflows: [AgentWorkflow], subagents: [AgentSubagent], truncated: Bool) {
        self.agent = agent
        self.supported = supported
        self.workflows = workflows
        self.subagents = subagents
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case agent, supported, workflows, subagents, truncated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = ((try? container.decodeIfPresent(String.self, forKey: .agent)) ?? nil) ?? ""
        supported = ((try? container.decodeIfPresent(Bool.self, forKey: .supported)) ?? nil) ?? true
        workflows = (((try? container.decodeIfPresent([AgentWorkflow].self, forKey: .workflows)) ?? nil) ?? [])
            .filter { !$0.id.isEmpty }
        subagents = (((try? container.decodeIfPresent([AgentSubagent].self, forKey: .subagents)) ?? nil) ?? [])
            .filter { !$0.id.isEmpty }
        truncated = ((try? container.decodeIfPresent(Bool.self, forKey: .truncated)) ?? nil) ?? false
    }

    var liveWorkflows: [AgentWorkflow] {
        supported ? workflows.filter { $0.running > 0 } : []
    }

    var liveSubagents: [AgentSubagent] {
        supported ? subagents.filter(\.running) : []
    }

    var runningAgents: Int {
        liveWorkflows.reduce(0) { $0 + $1.running } + liveSubagents.count
    }

    var hasWork: Bool {
        !liveWorkflows.isEmpty || !liveSubagents.isEmpty
    }

    var summary: String {
        let workflows = liveWorkflows.count
        let agents = runningAgents
        let left = workflows == 1 ? "1 workflow" : "\(workflows) workflows"
        let right = agents == 1 ? "1 agente" : "\(agents) agentes"
        return workflows == 0 ? right : "\(left) · \(right)"
    }
}

enum AgentWorkClock {
    static func short(_ ts: String, now: Date = Date()) -> String {
        guard let date = AgentChatClock.date(ts) else { return "" }
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "agora" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h" }
        return "\(hours / 24) d"
    }
}

struct AgentPulseMarks: View {
    var size: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            marks(active: -1)
        } else {
            TimelineView(.periodic(from: .now, by: 0.3)) { context in
                marks(active: Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3)
            }
        }
    }

    private func marks(active: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.slateTextDim)
                    .frame(width: size, height: size)
                    .opacity(active < 0 ? 0.55 : (active == index ? 1 : 0.2))
                    .animation(.easeInOut(duration: 0.28), value: active)
            }
        }
    }
}

struct AgentWorkBand: View {
    let work: AgentWorkPayload
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    AgentPulseMarks()
                    Text(work.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.slateTextFaint)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("trabalho em andamento: \(work.summary)")
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(work.liveWorkflows) { workflow in
                        detail(workflow.id, mark: "\(workflow.running)/\(workflow.total)", since: workflow.since)
                    }
                    ForEach(work.liveSubagents) { subagent in
                        detail(subagent.type.isEmpty ? subagent.id : subagent.type, mark: "", since: subagent.since)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
    }

    private func detail(_ name: String, mark: String, since: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
                .lineLimit(1)
                .truncationMode(.middle)
            if !mark.isEmpty {
                Text(mark)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            }
            Spacer(minLength: 4)
            Text(AgentWorkClock.short(since))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.slateTextFaint)
                .layoutPriority(1)
        }
    }
}

struct AgentWorkMark: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.on.square")
                .font(.system(size: 9, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(Color.slateText)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .glassSurface(shape: Capsule())
        .layoutPriority(1)
        .accessibilityElement()
        .accessibilityLabel("\(count) agentes em paralelo")
    }
}
