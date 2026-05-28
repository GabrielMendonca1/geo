import SwiftUI
import AppKit
import Foundation
import GRDB

struct NanoPane: View {
    @EnvironmentObject private var service: HermesStatusService
    @StateObject private var insights = TodayInsightsService()
    @StateObject private var activity = ActivityFeedService()
    @State private var dismissedErrorId: UUID?
    @State private var scrollTargetId: UUID?

    var body: some View {
        Pane {
            VStack(spacing: 0) {
                DashHeader(service: service, totalToday: insights.totalToday)
                Divider().overlay(Palette.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if service.setupState != .running {
                            HermesSetupBanner(service: service)
                        }
                        if let banner = recentError, service.setupState == .running {
                            ErrorBanner(event: banner) {
                                scrollTargetId = banner.id
                            } onDismiss: {
                                dismissedErrorId = banner.id
                            }
                        }

                        TodayCard(insights: insights)

                        HStack(alignment: .top, spacing: 24) {
                            ChannelsCard(service: service)
                            MemoryCard()
                        }

                        HStack(alignment: .top, spacing: 24) {
                            GeoCard { HermesCronsSection() }
                            GeoCard { WorkersCard() }
                        }

                        ActivityCard(events: activity.events, scrollTo: $scrollTargetId)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            insights.start()
            activity.start()
        }
        .onDisappear {
            insights.stop()
            activity.stop()
        }
        .onChange(of: activity.events.count) { _, _ in
            insights.refresh()
        }
    }

    private var recentError: ActivityEvent? {
        guard let last = activity.events.last,
              last.level >= 50,
              last.id != dismissedErrorId,
              Date().timeIntervalSince(last.timestamp) <= 60 else { return nil }
        return last
    }
}

// Header -----------------------------------------------------------------

private enum HealthVerdict {
    case healthy, degraded, down

    var label: String {
        switch self {
        case .healthy: return "Healthy"
        case .degraded: return "Degraded"
        case .down: return "Down"
        }
    }

    var dot: DashDot {
        switch self {
        case .healthy: return .green
        case .degraded: return .yellow
        case .down: return .red
        }
    }
}

private struct DashHeader: View {
    @ObservedObject var service: HermesStatusService
    let totalToday: Int
    @State private var feedback: String?
    @State private var feedbackIsError = false

    var body: some View {
        HStack(spacing: 14) {
            Text("Hermes")
                .font(GeoStyle.Typography.titleFont(size: 26))
                .foregroundStyle(Palette.foreground)

            StatusChip(verdict: verdict)

            Text("\(totalToday) handled")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.tertiaryForeground)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.5), value: totalToday)

            if let tick = service.lastTick {
                Text("· tick \(relativeTime(tick))")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiaryForeground.opacity(0.8))
            }

            if let feedback {
                Text(feedback)
                    .font(.system(size: 12))
                    .foregroundStyle(feedbackIsError ? Color(nsColor: Palette.agentDanger) : Palette.tertiaryForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }

            Spacer(minLength: 12)

            OpsPill(label: "Restart", icon: "arrow.clockwise", action: restartHermes)
            OpsPill(label: "SOUL", icon: "doc.text", action: openSoul)
            OpsPill(label: "Log", icon: "list.bullet.rectangle", action: tailLog)
            OpsPill(label: "Files", icon: "folder", action: revealHermes)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var verdict: HealthVerdict {
        guard service.setupState == .running, service.mcpConnected else { return .down }
        let bad = service.connectors.contains { c in
            switch c.status {
            case .error, .disconnected: return true
            case .connected, .connecting: return false
            }
        }
        return bad ? .degraded : .healthy
    }

    private func openSoul() {
        let path = NSString(string: "~/.hermes/SOUL.md").expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func tailLog() {
        let logURL = URL(fileURLWithPath: NSString(string: "~/.hermes/logs/gateway.log").expandingTildeInPath)
        let consoleURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([logURL], withApplicationAt: consoleURL, configuration: config) { _, error in
            if let error {
                show("console: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func restartHermes() {
        show("restarting…", isError: false)
        Task.detached {
            let uid = getuid()
            let target = "gui/\(uid)/ai.hermes.gateway"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", target]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    await MainActor.run { show("restarted hermes", isError: false) }
                } else {
                    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                    let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        if let msg, !msg.isEmpty {
                            show(msg, isError: true)
                        } else {
                            show("exit \(process.terminationStatus)", isError: true)
                        }
                    }
                }
            } catch {
                await MainActor.run { show(error.localizedDescription, isError: true) }
            }
        }
    }

    private func revealHermes() {
        let path = NSString(string: "~/.hermes").expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func show(_ text: String, isError: Bool) {
        feedback = text
        feedbackIsError = isError
        let snapshot = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if feedback == snapshot { feedback = nil }
        }
    }
}

private struct StatusChip: View {
    let verdict: HealthVerdict

    var body: some View {
        HStack(spacing: 7) {
            PulsingDot(dot: verdict.dot).frame(width: 12, height: 12)
            Text(verdict.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(verdict.dot.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(verdict.dot.color.opacity(0.12)))
    }
}

private struct OpsPill: View {
    let label: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(label).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(Palette.foreground)
            .background(Capsule().fill(hovering ? Palette.foreground.opacity(0.06) : Color.clear))
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering = $0 }
    }
}

// Card primitives --------------------------------------------------------

private struct GeoCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                Text(title)
                    .font(GeoStyle.Typography.titleFont(size: 17))
                    .foregroundStyle(Palette.foreground)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.background))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
    }
}

// Today ------------------------------------------------------------------

private struct TodayCard: View {
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

private struct ChannelBar: View {
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

// Channels ---------------------------------------------------------------

private struct ChannelsCard: View {
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

private struct ChannelRow: View {
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

private struct ConnectorDrawerItem: Identifiable { let id: String }

// Memory -----------------------------------------------------------------

private struct MemoryCard: View {
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

private struct MemorySpec {
    let name: String
    let tag: String
    let titleMatches: [String]
    let cap: Int?

    static let soul = MemorySpec(name: "Soul", tag: "soul", titleMatches: ["soul", "soul of geo"], cap: nil)
    static let memory = MemorySpec(name: "Memory", tag: "memory", titleMatches: ["memory", "geo memory"], cap: 2200)
    static let profile = MemorySpec(name: "User Profile", tag: "profile", titleMatches: ["user profile", "profile"], cap: 1375)
    static let all: [MemorySpec] = [.soul, .memory, .profile]
}

private struct MemoryLoadingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.tertiaryForeground.opacity(0.3)).frame(width: 6, height: 6)
            Text("loading…").font(.system(size: 13)).foregroundStyle(Palette.tertiaryForeground)
            Spacer()
        }
    }
}

private struct MemoryRow: View {
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

private struct UsageBar: View {
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

// Activity ---------------------------------------------------------------

private struct ActivityCard: View {
    let events: [ActivityEvent]
    @Binding var scrollTo: UUID?

    var body: some View {
        GeoCard(title: "Activity") {
            Group {
                if events.isEmpty {
                    Text("waiting for log events …")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.tertiaryForeground)
                        .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(events) { evt in
                                    ActivityRow(event: evt).id(evt.id)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(height: 300)
                        .onChange(of: events.last?.id) { _, newValue in
                            if let id = newValue {
                                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                            }
                        }
                        .onChange(of: scrollTo) { _, newValue in
                            if let id = newValue {
                                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { scrollTo = nil }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: kind.icon)
                .font(.system(size: 11))
                .foregroundStyle(kind.color)
                .frame(width: 16, alignment: .center)
            Text(Self.timeFormatter.string(from: event.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.tertiaryForeground.opacity(0.8))
            Text(event.msg)
                .font(.system(size: 13))
                .foregroundStyle(Palette.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            if let extra = event.extra {
                Text(extra)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.tertiaryForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if event.level >= 40 {
                Circle().fill(levelColor).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(event.level >= 40 ? levelColor.opacity(0.06) : Color.clear))
    }

    private var kind: EventKind { EventKind.from(event) }

    private var levelColor: Color {
        switch event.level {
        case ..<30: return Palette.tertiaryForeground
        case 30..<40: return Color(nsColor: Palette.agentSuccess)
        case 40..<50: return Color(nsColor: Palette.agentWarning)
        default: return Color(nsColor: Palette.agentDanger)
        }
    }
}

private enum EventKind {
    case telegram, whatsapp, gmail, memory, cron, observer, mcp, boot, llm, info, error
    var icon: String {
        switch self {
        case .telegram: return "paperplane.fill"
        case .whatsapp: return "bubble.left.fill"
        case .gmail: return "envelope.fill"
        case .memory: return "brain.head.profile"
        case .cron: return "clock.fill"
        case .observer: return "eye.fill"
        case .mcp: return "link"
        case .boot: return "power"
        case .llm: return "sparkles"
        case .info: return "circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    var color: Color {
        switch self {
        case .telegram: return Color(red: 0.15, green: 0.59, blue: 0.91)
        case .whatsapp: return Color(red: 0.07, green: 0.71, blue: 0.42)
        case .gmail: return Color(red: 0.96, green: 0.55, blue: 0.13)
        case .memory: return Color(red: 0.55, green: 0.40, blue: 0.93)
        case .cron: return Color(red: 0.95, green: 0.55, blue: 0.20)
        case .observer: return Color(red: 0.40, green: 0.40, blue: 0.45)
        case .mcp: return Color(red: 0.20, green: 0.50, blue: 0.85)
        case .boot: return Color(red: 0.35, green: 0.70, blue: 0.85)
        case .llm: return GeoColors.blue
        case .info: return Palette.tertiaryForeground
        case .error: return Color(nsColor: Palette.agentDanger)
        }
    }
    static func from(_ e: ActivityEvent) -> EventKind {
        if e.level >= 50 { return .error }
        let m = e.msg.lowercased()
        if m.contains("telegram") { return .telegram }
        if m.contains("whatsapp") { return .whatsapp }
        if m.contains("gmail") { return .gmail }
        if m.contains("memory:") || m.contains("memory ") || m.contains("soul-seeded") { return .memory }
        if m.contains("cron") { return .cron }
        if m.contains("observer") { return .observer }
        if m.contains("mcp") { return .mcp }
        if m.contains("boot") { return .boot }
        if m.contains("llm:") || m.contains("claude") { return .llm }
        return .info
    }
}

// Shared bits ------------------------------------------------------------

private enum DashDot { case green, yellow, red, gray
    var color: Color {
        switch self {
        case .green: return Color(nsColor: Palette.agentSuccess)
        case .yellow: return Color(nsColor: Palette.agentWarning)
        case .red: return Color(nsColor: Palette.agentDanger)
        case .gray: return Palette.tertiaryForeground
        }
    }
    var pulses: Bool { self == .green }
}

private struct PulsingDot: View {
    let dot: DashDot
    @State private var animate = false
    var body: some View {
        ZStack {
            if dot.pulses {
                Circle()
                    .fill(dot.color.opacity(0.5))
                    .frame(width: 12, height: 12)
                    .scaleEffect(animate ? 1.4 : 0.8)
                    .opacity(animate ? 0 : 0.6)
            }
            Circle().fill(dot.color).frame(width: 7, height: 7)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

private enum ChannelStyle {
    static func label(_ kind: String) -> String {
        switch kind {
        case "telegram": return "Telegram"
        case "whatsapp": return "WhatsApp"
        case "gmail": return "Gmail"
        case "nano": return "Nano"
        case "cron": return "Scheduled"
        case "cli": return "CLI"
        default: return kind.capitalized
        }
    }

    static func tint(_ kind: String) -> Color {
        switch kind {
        case "telegram": return Color(red: 0.15, green: 0.59, blue: 0.91)
        case "whatsapp": return Color(red: 0.07, green: 0.71, blue: 0.42)
        case "gmail": return Color(red: 0.96, green: 0.55, blue: 0.13)
        case "nano": return Color(red: 0.55, green: 0.40, blue: 0.93)
        default: return GeoColors.blue
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "telegram": return "paperplane.fill"
        case "whatsapp": return "bubble.left.fill"
        case "gmail": return "envelope.fill"
        case "nano": return "rectangle.grid.2x2.fill"
        default: return "circle.fill"
        }
    }
}

private enum GeoColors {
    static let blue = Color(red: 0.0, green: 0.33, blue: 1.0)
    static let blueLight = Color(red: 0.4, green: 0.6, blue: 1.0)
}

private func relativeTime(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
}

// Setup + error banners --------------------------------------------------

private struct HermesSetupBanner: View {
    @ObservedObject var service: HermesStatusService

    var body: some View {
        let copy = bannerCopy
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: copy.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(GeoColors.blue)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                Text(copy.body)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = copy.hint {
                    Text(hint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.tertiaryForeground.opacity(0.85))
                        .padding(.top, 1)
                }
                if let error = service.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Palette.agentDanger))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Button {
                copy.action()
            } label: {
                HStack(spacing: 5) {
                    if service.setupActionInFlight {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: copy.buttonIcon).font(.system(size: 11, weight: .medium))
                    }
                    Text(copy.buttonLabel).font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(GeoColors.blue))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(service.setupActionInFlight)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(GeoColors.blue.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(GeoColors.blue.opacity(0.30), lineWidth: 1))
    }

    private struct BannerCopy {
        let icon: String
        let title: String
        let body: String
        let hint: String?
        let buttonLabel: String
        let buttonIcon: String
        let action: () -> Void
    }

    private var bannerCopy: BannerCopy {
        switch service.setupState {
        case .notInstalled:
            return BannerCopy(
                icon: "shippingbox.fill",
                title: "Hermes is not installed",
                body: "Hermes is the always-on agent that powers Geo's Telegram, WhatsApp, and Gmail integration. Install it to enable channels and the kanban dispatch.",
                hint: "After install, run ./hermes/install.sh from this repo to seed config + ~/.hermes/.env.",
                buttonLabel: "Install Hermes",
                buttonIcon: "arrow.down.circle.fill",
                action: { [service] in service.installHermes() }
            )
        case .installedNotRunning:
            return BannerCopy(
                icon: "power.circle.fill",
                title: "Hermes is installed but not running",
                body: "The hermes binary is on PATH but the LaunchAgent is stopped. Start the gateway to enable channels.",
                hint: nil,
                buttonLabel: "Start Hermes",
                buttonIcon: "play.fill",
                action: { [service] in service.startGateway() }
            )
        case .running:
            return BannerCopy(
                icon: "checkmark.circle.fill",
                title: "Hermes is running",
                body: "",
                hint: nil,
                buttonLabel: "OK",
                buttonIcon: "checkmark",
                action: {}
            )
        }
    }
}

private struct ErrorBanner: View {
    let event: ActivityEvent
    let onView: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: Palette.agentDanger)).frame(width: 3)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: Palette.agentDanger))
            Text(event.msg)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: onView) {
                Text("view").font(.system(size: 12, weight: .medium)).foregroundStyle(GeoColors.blue)
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.tertiaryForeground)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: Palette.agentDanger).opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: Palette.agentDanger).opacity(0.25), lineWidth: 1))
    }
}

// Data feed --------------------------------------------------------------

private struct ActivityEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let level: Int
    let msg: String
    let extra: String?

    static func parse(_ line: String) -> ActivityEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timeMs = obj["time"] as? Double,
              let level = obj["level"] as? Int,
              let msg = obj["msg"] as? String else {
            return nil
        }
        var bits: [String] = []
        for key in ["identity", "channelId", "jid", "from", "target", "id"] {
            if let v = obj[key] as? String, !v.isEmpty {
                bits.append("\(key)=\(v)")
            }
        }
        if let err = obj["err"] as? String, !err.isEmpty {
            bits.append("err=\(err.prefix(120))")
        }
        let extra = bits.isEmpty ? nil : bits.joined(separator: " ")
        return ActivityEvent(
            timestamp: Date(timeIntervalSince1970: timeMs / 1000),
            level: level,
            msg: msg,
            extra: extra
        )
    }

    static func == (lhs: ActivityEvent, rhs: ActivityEvent) -> Bool { lhs.id == rhs.id }
}

@MainActor
private final class ActivityFeedService: ObservableObject {
    @Published private(set) var events: [ActivityEvent] = []

    private static let maxEvents = 200
    private static let minLevel = 30
    private static let tailBytes: UInt64 = 16 * 1024

    private var watcher: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var pendingBuffer: String = ""
    private let ioQueue = DispatchQueue(label: "ai.geo.activity.tail", qos: .utility)

    private var logURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".hermes/logs/gateway.log")
    }

    func start() {
        guard fileHandle == nil else { return }
        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        guard let fh = try? FileHandle(forReadingFrom: logURL) else { return }
        fileHandle = fh

        let size = (try? fh.seekToEnd()) ?? 0
        let startOffset = size > Self.tailBytes ? size - Self.tailBytes : 0
        do { try fh.seek(toOffset: startOffset) } catch {}
        if let initial = try? fh.readToEnd(), let str = String(data: initial, encoding: .utf8) {
            ingest(str)
        }
        installWatcher(fd: fh.fileDescriptor)
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        try? fileHandle?.close()
        fileHandle = nil
        pendingBuffer.removeAll()
    }

    private func installWatcher(fd: Int32) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.extend, .delete, .rename],
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                Task { @MainActor in
                    self.stop()
                    self.start()
                }
                return
            }
            let data = self.fileHandle.flatMap { try? $0.readToEnd() } ?? Data()
            let chunk = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                self.ingest(chunk)
            }
        }
        source.resume()
        watcher = source
    }

    private func ingest(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        pendingBuffer.append(chunk)
        while let nl = pendingBuffer.firstIndex(of: "\n") {
            let line = String(pendingBuffer[..<nl])
            pendingBuffer.removeSubrange(...nl)
            if let evt = ActivityEvent.parse(line), evt.level >= Self.minLevel {
                append(evt)
            }
        }
    }

    private func append(_ event: ActivityEvent) {
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }
}

@MainActor
private final class TodayInsightsService: ObservableObject {
    struct ChannelCount: Equatable { let kind: String; let count: Int }
    struct LastReply: Equatable { let kind: String; let ts: Date; let text: String }

    @Published private(set) var totalToday: Int = 0
    @Published private(set) var perChannel: [ChannelCount] = []
    @Published private(set) var lastReply: LastReply?
    @Published private(set) var todayLabels: [String] = []

    private var db: DatabaseQueue?
    private var refreshTask: Task<Void, Never>?
    private let dbQueue = DispatchQueue(label: "ai.geo.today.insights", qos: .userInitiated)

    private var dbPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".hermes/state.db").path
    }

    func start() {
        guard db == nil else { return }
        openDb()
        refresh()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        db = nil
    }

    private func openDb() {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            var config = Configuration()
            config.readonly = true
            db = try DatabaseQueue(path: dbPath, configuration: config)
        } catch {
            db = nil
        }
    }

    func refresh() {
        if db == nil { openDb() }
        guard let db else { return }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let startOfDaySec = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970

            do {
                let (perChannel, lastReply) = try await Self.query(db: db, startOfDaySec: startOfDaySec)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.perChannel = perChannel
                    self.totalToday = perChannel.reduce(0) { $0 + $1.count }
                    self.lastReply = lastReply
                    self.todayLabels = self.deriveLabels(from: perChannel)
                }
            } catch {
            }
        }
    }

    nonisolated private static func query(
        db: DatabaseQueue,
        startOfDaySec: Double
    ) async throws -> ([ChannelCount], LastReply?) {
        try await Task.detached(priority: .userInitiated) {
            try db.read { d in
                let rows = try Row.fetchAll(d, sql: """
                    SELECT s.source AS kind, COUNT(*) AS n
                    FROM messages m
                    JOIN sessions s ON s.id = m.session_id
                    WHERE m.timestamp >= ?
                      AND m.role = 'user'
                    GROUP BY s.source
                    ORDER BY n DESC
                """, arguments: [startOfDaySec])

                let counts: [ChannelCount] = rows.map { r in
                    ChannelCount(kind: r["kind"] ?? "unknown", count: r["n"] ?? 0)
                }

                let lastRow = try Row.fetchOne(d, sql: """
                    SELECT s.source AS kind, m.content AS content, m.timestamp AS ts
                    FROM messages m
                    JOIN sessions s ON s.id = m.session_id
                    WHERE m.role = 'assistant'
                    ORDER BY m.timestamp DESC
                    LIMIT 1
                """)
                var last: LastReply? = nil
                if let r = lastRow {
                    let kind: String = r["kind"] ?? "unknown"
                    let content: String = r["content"] ?? ""
                    let ts: Double = r["ts"] ?? 0
                    last = LastReply(
                        kind: kind,
                        ts: Date(timeIntervalSince1970: ts),
                        text: extractText(content)
                    )
                }
                return (counts, last)
            }
        }.value
    }

    private func deriveLabels(from perChannel: [ChannelCount]) -> [String] {
        var out: [String] = []
        let total = perChannel.reduce(0) { $0 + $1.count }
        if total == 0 { return out }
        if let top = perChannel.first {
            out.append("most active · \(top.kind)")
        }
        if total >= 10 { out.append("busy day") }
        else if total >= 3 { out.append("steady") }
        else { out.append("quiet morning") }
        return out
    }

    nonisolated private static func extractText(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { return json }
        return text
    }
}
