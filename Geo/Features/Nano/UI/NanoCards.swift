import SwiftUI
import AppKit
import Foundation

struct TodayCard: View {
    @ObservedObject var insights: TodayInsightsService

    var body: some View {
        GeoCard(title: "Today") {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(insights.totalToday)")
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .foregroundStyle(GeoColors.blue)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.5), value: insights.totalToday)
                    Text(insights.totalToday == 1 ? "message handled" : "messages handled")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.tertiaryForeground)
                }
                .frame(width: 150, alignment: .leading)

                VStack(alignment: .leading, spacing: 9) {
                    if insights.perChannel.isEmpty {
                        Text("nothing yet — geo is awake and waiting")
                            .font(.system(size: 13))
                            .italic()
                            .foregroundStyle(Palette.tertiaryForeground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        let maxCount = insights.perChannel.map(\.count).max() ?? 1
                        ForEach(insights.perChannel, id: \.kind) { item in
                            HStack(spacing: 12) {
                                Text(ChannelStyle.label(item.kind))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Palette.foreground)
                                    .frame(width: 80, alignment: .leading)
                                ChannelBar(value: item.count, max: maxCount, tint: ChannelStyle.tint(item.kind))
                                    .frame(height: 8)
                                Text("\(item.count)")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Palette.tertiaryForeground)
                                    .frame(width: 28, alignment: .trailing)
                            }
                        }
                    }

                    if !insights.todayLabels.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(insights.todayLabels, id: \.self) { label in
                                Text(label)
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Capsule().fill(GeoColors.blue.opacity(0.10)))
                                    .foregroundStyle(GeoColors.blue)
                            }
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)

                if let reply = insights.lastReply {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: ChannelStyle.icon(reply.kind))
                                .font(.system(size: 10))
                            Text("\(reply.kind) · \(relativeTime(reply.ts))")
                                .font(.system(size: 10, weight: .semibold))
                                .textCase(.uppercase)
                                .tracking(0.5)
                        }
                        .foregroundStyle(Palette.tertiaryForeground)
                        Text(reply.text)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.foreground)
                            .lineLimit(3)
                            .padding(.leading, 10)
                            .overlay(
                                Rectangle().fill(GeoColors.blue.opacity(0.5)).frame(width: 2),
                                alignment: .leading
                            )
                        Text("most recent reply")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.tertiaryForeground.opacity(0.7))
                    }
                    .frame(width: 240, alignment: .leading)
                }
            }
        }
    }
}

struct ChannelBar: View {
    let value: Int
    let max: Int
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.secondaryBackground)
                Capsule()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(Double(value) / Double(Swift.max(max, 1))))
                    .animation(.easeOut(duration: 0.6), value: value)
            }
        }
    }
}

struct ChannelsCard: View {
    @ObservedObject var service: HermesStatusService
    @State private var connectorDrawer: String?

    var body: some View {
        GeoCard(title: "Channels") {
            VStack(alignment: .leading, spacing: 10) {
                ChannelRow(
                    name: "MCP",
                    detail: service.mcpConnected ? "connected" : (service.mcpError ?? "down"),
                    dot: service.mcpConnected ? .green : .red,
                    tap: nil
                )
                ForEach(service.connectors) { c in
                    ChannelRow(
                        name: c.name,
                        detail: c.identity ?? c.status.label,
                        dot: dotColor(for: c.status),
                        tap: { connectorDrawer = c.id }
                    )
                }
                Divider().overlay(Palette.border).padding(.vertical, 2)
                HStack(spacing: 16) {
                    Label("provider: \(service.provider)", systemImage: "cpu")
                    if let tick = service.lastTick {
                        Label("last tick \(relativeTime(tick))", systemImage: "clock")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiaryForeground)
            }
        }
        .sheet(item: Binding(
            get: { connectorDrawer.map { ConnectorDrawerItem(id: $0) } },
            set: { connectorDrawer = $0?.id }
        )) { item in
            ConnectorDrawer(id: item.id).environmentObject(service)
        }
    }

    private func dotColor(for status: HermesConnectionStatus) -> DashDot {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .error: return .red
        }
    }
}

struct ChannelRow: View {
    let name: String
    let detail: String
    let dot: DashDot
    let tap: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let row = HStack(spacing: 11) {
            PulsingDot(dot: dot).frame(width: 12, height: 12)
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.foreground)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Palette.tertiaryForeground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if tap != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.tertiaryForeground.opacity(hovering ? 0.9 : 0.4))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.secondaryBackground : Color.clear))
        .contentShape(Rectangle())

        if let tap {
            Button(action: tap) { row }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .onHover { hovering = $0 }
        } else {
            row
        }
    }
}

struct ConnectorDrawerItem: Identifiable { let id: String }

struct MemoryCard: View {
    @EnvironmentObject private var blocksStore: BlocksStore
    @State private var memoryIndex: [String: BlocksStore.Block] = [:]

    var body: some View {
        GeoCard(title: "Memory") {
            VStack(alignment: .leading, spacing: 12) {
                if blocksStore.blocks.isEmpty {
                    MemoryLoadingRow()
                } else {
                    MemoryRow(spec: .soul, block: memoryIndex[MemorySpec.soul.tag])
                    MemoryRow(spec: .memory, block: memoryIndex[MemorySpec.memory.tag])
                    MemoryRow(spec: .profile, block: memoryIndex[MemorySpec.profile.tag])
                }
                Divider().overlay(Palette.border).padding(.vertical, 2)
                Text("Edit any of these blocks in the Blocks pane to change what the agent knows. Restart the daemon to pick up Soul edits.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { rebuildMemoryIndex(blocksStore.blocks) }
        .onChange(of: blocksStore.blocks) { _, newValue in
            rebuildMemoryIndex(newValue)
        }
    }

    private func rebuildMemoryIndex(_ blocks: [BlocksStore.Block]) {
        let specs = MemorySpec.all
        var byTag: [String: BlocksStore.Block] = [:]
        var byTitle: [String: BlocksStore.Block] = [:]
        let tagNeedles: [(spec: MemorySpec, needle: String)] = specs.map { ($0, "tag: \($0.tag)") }
        let titleNeedles: [String: String] = specs.reduce(into: [:]) { acc, spec in
            for t in spec.titleMatches { acc[t.lowercased()] = spec.tag }
        }
        for block in blocks {
            if byTag.count < specs.count {
                for (spec, needle) in tagNeedles where byTag[spec.tag] == nil {
                    if block.markdown.contains(needle) {
                        byTag[spec.tag] = block
                    }
                }
            }
            let normalizedTitle = block.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let specTag = titleNeedles[normalizedTitle], byTitle[specTag] == nil {
                byTitle[specTag] = block
            }
            if byTag.count == specs.count { break }
        }
        var merged: [String: BlocksStore.Block] = byTag
        for spec in specs where merged[spec.tag] == nil {
            if let titled = byTitle[spec.tag] {
                merged[spec.tag] = titled
            }
        }
        memoryIndex = merged
    }
}

struct MemorySpec {
    let name: String
    let tag: String
    let titleMatches: [String]
    let cap: Int?

    static let soul = MemorySpec(name: "Soul", tag: "soul", titleMatches: ["soul", "soul of geo"], cap: nil)
    static let memory = MemorySpec(name: "Memory", tag: "memory", titleMatches: ["memory", "geo memory"], cap: 2200)
    static let profile = MemorySpec(name: "User Profile", tag: "profile", titleMatches: ["user profile", "profile"], cap: 1375)
    static let all: [MemorySpec] = [.soul, .memory, .profile]
}

struct MemoryLoadingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.tertiaryForeground.opacity(0.3)).frame(width: 6, height: 6)
            Text("loading…").font(.system(size: 13)).foregroundStyle(Palette.tertiaryForeground)
            Spacer()
        }
    }
}

struct MemoryRow: View {
    let spec: MemorySpec
    let block: BlocksStore.Block?
    @EnvironmentObject private var blocksStore: BlocksStore
    @Environment(\.openWindow) private var openWindow
    @State private var creating = false
    @State private var hovering = false

    var body: some View {
        if let block {
            populated(block)
        } else {
            empty()
        }
    }

    private var purple: Color { Color(red: 0.55, green: 0.40, blue: 0.93) }

    @ViewBuilder
    private func populated(_ block: BlocksStore.Block) -> some View {
        let preview = bodyPreview(block.markdown)
        let chars = bodyCharCount(block.markdown)
        Button(action: { MenuActions.openBlockEditor(block.id, openWindow: openWindow) }) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(purple).frame(width: 6, height: 6)
                    Text(spec.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.foreground)
                    Spacer(minLength: 0)
                    Text(usageLabel(chars: chars))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(usageColor(chars: chars))
                    Text(relativeTime(block.lastEdited))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.tertiaryForeground.opacity(0.8))
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiaryForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 14)
                }
                if spec.cap != nil {
                    UsageBar(chars: chars, cap: spec.cap!).frame(height: 3).padding(.leading, 14)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.secondaryBackground : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func empty() -> some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.tertiaryForeground.opacity(0.3)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(spec.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.foreground)
                Text("not seeded").font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground)
            }
            Spacer()
            Button(action: createBlock) {
                Text(creating ? "creating…" : "create")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(purple.opacity(0.15)))
                    .foregroundStyle(purple)
            }
            .buttonStyle(.plain)
            .disabled(creating)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func createBlock() {
        guard !creating else { return }
        creating = true
        let title = spec.name
        let markdown = "---\ntag: \(spec.tag)\nsymphony: false\n---\n\n# \(title)\n\n"
        Task { @MainActor in
            _ = await blocksStore.createBlock(title: title, markdown: markdown)
            creating = false
        }
    }

    private func bodyPreview(_ markdown: String) -> String {
        let stripped = stripFrontmatter(markdown)
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count <= 80 { return stripped }
        return String(stripped.prefix(80)) + "…"
    }

    private func bodyCharCount(_ markdown: String) -> Int {
        stripFrontmatter(markdown)
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .count
    }

    private func stripFrontmatter(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return markdown
        }
        var idx = 1
        while idx < lines.count {
            if lines[idx].trimmingCharacters(in: .whitespaces) == "---" {
                return lines.dropFirst(idx + 1).joined(separator: "\n")
            }
            idx += 1
        }
        return markdown
    }

    private func usageLabel(chars: Int) -> String {
        if let cap = spec.cap { return "\(chars) / \(cap)" }
        return "\(chars)"
    }

    private func usageColor(chars: Int) -> Color {
        guard let cap = spec.cap, cap > 0 else { return Palette.tertiaryForeground }
        let ratio = Double(chars) / Double(cap)
        if ratio > 0.85 { return Color(nsColor: Palette.agentDanger) }
        if ratio > 0.60 { return Color(nsColor: Palette.agentWarning) }
        return Color(nsColor: Palette.agentSuccess)
    }
}

struct UsageBar: View {
    let chars: Int
    let cap: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.secondaryBackground)
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * CGFloat(min(ratio, 1.0)))
                    .animation(.easeOut(duration: 0.4), value: chars)
            }
        }
    }

    private var ratio: Double {
        guard cap > 0 else { return 0 }
        return Double(chars) / Double(cap)
    }

    private var tint: Color {
        if ratio > 0.85 { return Color(nsColor: Palette.agentDanger) }
        if ratio > 0.60 { return Color(nsColor: Palette.agentWarning) }
        return Color(nsColor: Palette.agentSuccess)
    }
}
