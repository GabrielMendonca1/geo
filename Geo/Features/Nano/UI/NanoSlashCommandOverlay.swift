import SwiftUI

struct NanoSlashCommand: Identifiable {
    let id: String
    let label: String
    let hint: String
    let expansion: String

    static let all: [NanoSlashCommand] = [
        .init(id: "today", label: "/today", hint: "Summarize today's day record + tasks", expansion: "What's on today?"),
        .init(id: "search", label: "/search ", hint: "Search my blocks", expansion: "Search my blocks for: "),
        .init(id: "tasks", label: "/tasks", hint: "List my open tasks", expansion: "List my open tasks for this week."),
        .init(id: "dispatch", label: "/dispatch ", hint: "Dispatch a sub-agent", expansion: "Dispatch an agent to: "),
        .init(id: "summary", label: "/summary", hint: "Summarize recent WhatsApp + Gmail", expansion: "Summarize what's happened on my channels in the last 24h."),
        .init(id: "clear", label: "/clear", hint: "New conversation (clears warm session)", expansion: "/clear"),
    ]
}

struct NanoSlashCommandOverlay: View {
    @Binding var draft: String
    let onSelect: (NanoSlashCommand) -> Void

    private var visibleCommands: [NanoSlashCommand] {
        guard draft.hasPrefix("/") else { return [] }
        let query = String(draft.dropFirst()).lowercased()
        if query.isEmpty { return NanoSlashCommand.all }
        return NanoSlashCommand.all.filter {
            $0.id.lowercased().hasPrefix(query) || $0.label.lowercased().contains(query)
        }
    }

    var body: some View {
        if !visibleCommands.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleCommands) { cmd in
                    Button {
                        onSelect(cmd)
                    } label: {
                        HStack(spacing: 10) {
                            Text(cmd.label)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(red: 0.0, green: 0.33, blue: 1.0))
                                .frame(width: 90, alignment: .leading)
                            Text(cmd.hint)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if cmd.id != visibleCommands.last?.id {
                        Divider().opacity(0.2)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
