import SwiftUI

struct TurnSection: View {
    let report: TaskNodeReport
    let turnIndex: Int
    let linkedIssueState: String?
    let onApplyNextState: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            turnLabel
            if let prompt = report.prompt, !prompt.isEmpty {
                PromptBubble(prompt: prompt)
            }
            reportBubble
        }
    }

    private var turnLabel: some View {
        Text("TURN \(turnIndex + 1)")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    private var reportBubble: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarCircle(
                symbol: report.agentKind?.symbolName ?? "sparkles",
                tint: report.agentKind?.tint ?? Color.orange,
                background: (report.agentKind?.tint ?? Color.orange).opacity(0.14)
            )
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(report.agentKind?.label ?? report.agentLabel ?? "Agent")
                        .font(.system(size: 12, weight: .semibold))
                    if let date = report.timestampDate {
                        Text("·").foregroundStyle(Color.secondary.opacity(0.6))
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else if let ts = report.timestamp, !ts.isEmpty {
                        Text("·").foregroundStyle(Color.secondary.opacity(0.6))
                        Text(ts)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                let parts = ReportSectionPart.parse(report.body)
                ForEach(parts) { part in
                    ReportSectionView(part: part)
                }
                if let nextState = suggestedNextState(from: report.body),
                   nextState != linkedIssueState {
                    nextStateButton(nextState)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func suggestedNextState(from body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        var captureFrom: Int? = nil
        for (idx, line) in lines.enumerated() {
            let stripped = line.trimmingCharacters(in: .whitespaces).lowercased()
            if stripped.hasPrefix("## next") || stripped.hasPrefix("### next") {
                captureFrom = idx + 1
                break
            }
        }
        guard let start = captureFrom else { return nil }
        var captureUntil = lines.count
        for idx in start..<lines.count {
            let stripped = lines[idx].trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("## ") || stripped.hasPrefix("### ") {
                captureUntil = idx
                break
            }
        }
        guard start < captureUntil else { return nil }
        let tail = lines[start..<captureUntil].joined(separator: " ").lowercased()
        let aliases: [(String, String)] = [
            ("human review", "Human Review"),
            ("in review", "Human Review"),
            ("in progress", "In Progress"),
            ("cancelled", "Canceled"),
            ("canceled", "Canceled"),
            ("backlog", "Backlog"),
            ("merging", "Merging"),
            ("rework", "Rework"),
            ("review", "Human Review"),
            ("todo", "Todo"),
            ("done", "Done")
        ]
        for (needle, state) in aliases where tail.contains(needle) {
            return state
        }
        return nil
    }

    @ViewBuilder
    private func nextStateButton(_ state: String) -> some View {
        Button {
            onApplyNextState(state)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.forward.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Move to \(state)")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor)
            )
        }
        .buttonStyle(.plain)
        .help("Apply the agent's recommended next state")
    }
}

struct PendingTurnBubble: View {
    let prompt: String
    let turnNumber: Int
    let agentKind: AIAgentKind?
    let toolCalls: [AIToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("TURN \(turnNumber) · PENDING")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            PromptBubble(prompt: prompt)
            thinkingBubble
        }
    }

    private var thinkingBubble: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarCircle(
                symbol: agentKind?.symbolName ?? "sparkles",
                tint: agentKind?.tint ?? Color.orange,
                background: (agentKind?.tint ?? Color.orange).opacity(0.14)
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(agentKind?.label ?? "Claude Code")
                    .font(.system(size: 12, weight: .semibold))
                let recent = Array(toolCalls.suffix(6))
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(recent) { call in
                        toolCallRow(call)
                    }
                    HStack(spacing: 6) {
                        PendingShimmer()
                        Text(recent.isEmpty ? "Thinking…" : "Working…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func toolCallRow(_ call: AIToolCall) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: call.kind.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Text(toolCallVerb(call.kind))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if let target = call.target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
                Text(compactTarget(target))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func toolCallVerb(_ kind: AIToolCall.Kind) -> String {
        switch kind {
        case .read: return "Read"
        case .edit: return "Edited"
        case .write: return "Wrote"
        case .run: return "Ran"
        case .search: return "Searched"
        case .other: return "Used"
        }
    }

    private func compactTarget(_ target: String) -> String {
        let home = NSHomeDirectory()
        if target.hasPrefix(home) {
            return "~" + String(target.dropFirst(home.count))
        }
        return target
    }
}

struct PromptBubble: View {
    let prompt: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarCircle(symbol: "person.fill", tint: Color.primary.opacity(0.55), background: Color.primary.opacity(0.08))
            VStack(alignment: .leading, spacing: 4) {
                Text("You")
                    .font(.system(size: 12, weight: .semibold))
                MarkdownText(markdown: prompt)
                    .padding(.top, 2)
            }
        }
    }
}

struct ReportSectionView: View {
    let part: ReportSectionPart

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = part.title, !title.isEmpty, !isHiddenSectionTitle(title) {
                Text(formattedSectionTitle(title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.62))
            }
            if !part.body.isEmpty {
                MarkdownText(markdown: part.body)
            }
        }
    }

    private func isHiddenSectionTitle(_ raw: String) -> Bool {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return lower == "summary"
            || lower == "next recommended state"
            || lower == "next state"
            || lower == "next"
    }

    private func formattedSectionTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
    }
}

struct ReportSectionPart: Identifiable {
    let id: String
    var title: String?
    var body: String

    static func parse(_ raw: String) -> [ReportSectionPart] {
        let lines = raw.components(separatedBy: "\n")
        var result: [ReportSectionPart] = []
        var currentTitle: String? = nil
        var buffer: [String] = []
        var seen: Set<String> = []

        func makeStableID(_ title: String?) -> String {
            let base = title?.lowercased() ?? "intro"
            var candidate = base
            var n = 2
            while seen.contains(candidate) {
                candidate = "\(base)#\(n)"
                n += 1
            }
            seen.insert(candidate)
            return candidate
        }

        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if currentTitle != nil || !body.isEmpty {
                result.append(ReportSectionPart(id: makeStableID(currentTitle), title: currentTitle, body: body))
            }
            currentTitle = nil
            buffer = []
        }

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("### ") {
                flush()
                currentTitle = String(stripped.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if stripped.hasPrefix("## ") {
                flush()
                currentTitle = String(stripped.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }
}

struct AvatarCircle: View {
    let symbol: String
    let tint: Color
    let background: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(background)
                .frame(width: 26, height: 26)
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
        .overlay(
            Circle()
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

struct PendingShimmer: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.85))
            .frame(width: 6, height: 6)
            .scaleEffect(0.7 + 0.45 * phase)
            .opacity(0.45 + 0.55 * phase)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
    }
}

struct MarkdownText: View {
    let markdown: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(markdown)
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension AIToolCall.Kind {
    var symbolName: String {
        switch self {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .write: return "square.and.pencil"
        case .run: return "terminal"
        case .search: return "magnifyingglass"
        case .other: return "circle.dotted"
        }
    }
}
