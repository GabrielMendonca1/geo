import SwiftUI

struct NanoConversationListView: View {
    @EnvironmentObject private var store: NanoConversationStore
    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider().opacity(0.3)
            list
        }
        .frame(width: 240)
        .background(Color.secondary.opacity(0.06))
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: 1),
            alignment: .trailing
        )
        .task { await store.refreshConversations() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Conversations")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await store.newConversation() }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New conversation")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filtered) { conv in
                    Button {
                        Task { await store.switchTo(channelId: conv.id) }
                    } label: {
                        row(for: conv)
                    }
                    .buttonStyle(.plain)
                }
                if filtered.isEmpty {
                    Text("No conversations yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
            }
            .padding(6)
        }
    }

    private func row(for conv: NanoConversationSummary) -> some View {
        let isActive = conv.id == store.channelId
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(conv.title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(conv.messageCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            Text(relativeDate(conv.lastTs))
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color(red: 0.0, green: 0.33, blue: 1.0).opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var filtered: [NanoConversationSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return store.conversations }
        return store.conversations.filter { $0.title.lowercased().contains(q) }
    }

    private func relativeDate(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
