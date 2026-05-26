import SwiftUI

struct IssueSidebar: View {
    let linkedIssue: AIIssue?
    let projectName: String?
    let toolCalls: [AIToolCall]
    let agentKind: AIAgentKind?
    let statusState: String
    let statusLabel: String
    let statusIcon: String
    let statusColor: Color
    let onUpdateState: (String) -> Void
    var onUpdatePriority: (Int?) -> Void = { _ in }
    var onUpdateModel: (String?) -> Void = { _ in }
    var onUpdateEffort: (String?) -> Void = { _ in }
    var defaultModelDisplay: String = "Opus"
    var defaultEffortDisplay: String = "medium"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                row(label: "STATUS") { statusPill }
                row(label: "PRIORITY") { priorityPill }
                row(label: "AGENT") { agentPill }
                row(label: "MODEL") { modelPill }
                row(label: "EFFORT") { effortPill }
                row(label: "LABELS") { labelsRow }
                if let projectName {
                    row(label: "PROJECT") {
                        Text(projectName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }
                if !toolCalls.isEmpty {
                    row(label: "ACTIVITY") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(toolCalls.suffix(12)) { call in
                                HStack(spacing: 6) {
                                    Image(systemName: call.kind.symbolName)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 12)
                                    Text(call.target ?? call.name)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.primary.opacity(0.78))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
        }
    }

    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private var statusPill: some View {
        Menu {
            ForEach(["Backlog", "Todo", "In Progress", "Human Review", "Rework", "Merging", "Done", "Canceled"], id: \.self) { state in
                Button {
                    onUpdateState(state)
                } label: {
                    Label(state, systemImage: state.caseInsensitiveCompare(statusState) == .orderedSame ? "checkmark" : "circle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(statusLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(linkedIssue == nil)
    }

    private var priorityPill: some View {
        let current = linkedIssue?.priority
        return Menu {
            Button {
                onUpdatePriority(nil)
            } label: {
                Label("No priority", systemImage: current == nil ? "checkmark" : "circle")
            }
            ForEach([0, 1, 2, 3], id: \.self) { value in
                Button {
                    onUpdatePriority(value)
                } label: {
                    Label(priorityLabel(value), systemImage: current == value ? "checkmark" : "circle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let p = current {
                    Image(systemName: prioritySymbol(p))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(priorityLabel(p))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                } else {
                    Text("No priority")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(linkedIssue == nil)
    }

    private var agentPill: some View {
        HStack(spacing: 6) {
            Image(systemName: agentKind?.symbolName ?? "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(agentKind?.tint ?? Color.orange)
            Text(agentKind?.label ?? "Claude Code")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    private var modelPill: some View {
        let current = linkedIssue?.symphonyModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (current?.isEmpty ?? true) ? nil : current
        return Menu {
            Button {
                onUpdateModel(nil)
            } label: {
                Label("Default", systemImage: normalized == nil ? "checkmark" : "circle")
            }
            ForEach(["opus", "sonnet", "haiku"], id: \.self) { value in
                Button {
                    onUpdateModel(value)
                } label: {
                    Label(value.capitalized, systemImage: normalized?.caseInsensitiveCompare(value) == .orderedSame ? "checkmark" : "circle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(normalized?.capitalized ?? "Default · \(defaultModelDisplay)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(normalized == nil ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(Color.primary.opacity(0.85)))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(linkedIssue == nil)
    }

    private var effortPill: some View {
        let current = linkedIssue?.symphonyEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (current?.isEmpty ?? true) ? nil : current
        return Menu {
            Button {
                onUpdateEffort(nil)
            } label: {
                Label("Default", systemImage: normalized == nil ? "checkmark" : "circle")
            }
            ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { value in
                Button {
                    onUpdateEffort(value)
                } label: {
                    Label(value.capitalized, systemImage: normalized?.caseInsensitiveCompare(value) == .orderedSame ? "checkmark" : "circle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(normalized?.capitalized ?? "Default · \(defaultEffortDisplay)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(normalized == nil ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(Color.primary.opacity(0.85)))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(linkedIssue == nil)
    }

    private var labelsRow: some View {
        let labels = (linkedIssue?.labels ?? []).filter { !$0.isEmpty }
        return Group {
            if labels.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("No labels")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(labels, id: \.self) { label in
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                }
            }
        }
    }

    private func prioritySymbol(_ p: Int) -> String {
        switch p {
        case 1: return "exclamationmark.3"
        case 2: return "exclamationmark.2"
        case 3: return "exclamationmark"
        default: return "circle.fill"
        }
    }

    private func priorityLabel(_ p: Int) -> String {
        switch p {
        case 0: return "Urgent"
        case 1: return "High"
        case 2: return "Medium"
        case 3: return "Low"
        default: return "P\(p)"
        }
    }
}
