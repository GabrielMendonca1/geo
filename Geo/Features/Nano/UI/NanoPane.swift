import SwiftUI
import AppKit
import Foundation
import GRDB

// Geo pane — mission control for the always-on geo-claw daemon.
// The chat surface moved to Telegram. This pane is the dashboard.
//
// Composition (top → bottom):
//   ┌─ TodayInsightsCard ───────────────────────────────────┐  hero: today's activity at a glance
//   ┌─ ActivatedCard ───────────────────────────────────────┐  compact strip: connectors + MCP
//   ┌─ CronsCard ──────────┐ ┌─ MemoryCard ─┐                 crons grid + memory legend
//   ┌─ ActivityFeed ────────────────────────────────────────┐  live tail of claw.log
//
// Data sources:
//   - NanoClawService       (EnvironmentObject) — watches status.json
//   - TodayInsightsService  (@StateObject)      — reads claw.sqlite via GRDB for daily aggregates
//   - ActivityFeedService   (@StateObject)      — tails claw.log via DispatchSource

struct NanoPane: View {
    @EnvironmentObject private var service: NanoClawService
    @StateObject private var insights = TodayInsightsService()
    @StateObject private var activity = ActivityFeedService()

    var body: some View {
        Pane {
            VStack(spacing: 12) {
                TodayInsightsCard(insights: insights)
                ActivatedStrip(service: service)
                HStack(alignment: .top, spacing: 12) {
                    CronsCard()
                        .frame(maxWidth: .infinity)
                    MemoryCard()
                        .frame(width: 260)
                }
                ActivityFeed(events: activity.events)
                    .frame(maxHeight: .infinity)
            }
            .padding(14)
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
            // Any new log event might mean new messages/memory/cron runs — refresh insights.
            insights.refresh()
        }
    }
}

// MARK: - Today insights (hero card) ------------------------------------

private struct TodayInsightsCard: View {
    @ObservedObject var insights: TodayInsightsService

    var body: some View {
        DashCard(title: "Today", icon: "sparkles", accent: GeoColors.blue) {
            HStack(alignment: .top, spacing: 18) {
                // Big number on the left
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(insights.totalToday)")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [GeoColors.blue, GeoColors.blueLight],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.5), value: insights.totalToday)
                    Text(insights.totalToday == 1 ? "message handled" : "messages handled")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 130, alignment: .leading)

                Divider().frame(height: 60)

                // Per-channel bars in the middle
                VStack(alignment: .leading, spacing: 5) {
                    if insights.perChannel.isEmpty {
                        Text("nothing yet — geo is awake and waiting")
                            .font(.system(size: 11))
                            .italic()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        let maxCount = insights.perChannel.map(\.count).max() ?? 1
                        ForEach(insights.perChannel, id: \.kind) { item in
                            HStack(spacing: 8) {
                                Text(label(for: item.kind))
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 64, alignment: .leading)
                                ChannelBar(value: item.count, max: maxCount, tint: tint(for: item.kind))
                                    .frame(height: 6)
                                Text("\(item.count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                            }
                        }
                    }

                    if insights.todayLabels.count > 0 {
                        HStack(spacing: 10) {
                            ForEach(insights.todayLabels, id: \.self) { label in
                                Text(label)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(GeoColors.blue.opacity(0.10))
                                    )
                                    .foregroundStyle(GeoColors.blue)
                            }
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)

                // Last reply preview on the right
                if let reply = insights.lastReply {
                    Divider().frame(height: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: icon(for: reply.kind))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text("\(reply.kind) · \(relative(reply.ts))")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.5)
                        }
                        Text(reply.text)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .padding(.leading, 8)
                            .overlay(
                                Rectangle()
                                    .fill(GeoColors.blue.opacity(0.5))
                                    .frame(width: 2),
                                alignment: .leading
                            )
                        Text("most recent reply")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    .frame(width: 220, alignment: .leading)
                }
            }
        }
    }

    private func label(for kind: String) -> String {
        switch kind {
        case "telegram": return "Telegram"
        case "whatsapp": return "WhatsApp"
        case "gmail": return "Gmail"
        case "nano": return "Nano"
        default: return kind.capitalized
        }
    }

    private func tint(for kind: String) -> Color {
        switch kind {
        case "telegram": return Color(red: 0.15, green: 0.59, blue: 0.91)
        case "whatsapp": return Color(red: 0.07, green: 0.71, blue: 0.42)
        case "gmail": return Color(red: 0.96, green: 0.55, blue: 0.13)
        case "nano": return Color(red: 0.55, green: 0.40, blue: 0.93)
        default: return GeoColors.blue
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "telegram": return "paperplane.fill"
        case "whatsapp": return "bubble.left.fill"
        case "gmail": return "envelope.fill"
        case "nano": return "rectangle.grid.2x2.fill"
        default: return "circle.fill"
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct ChannelBar: View {
    let value: Int
    let max: Int
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.6)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(Double(value) / Double(Swift.max(max, 1))))
                    .animation(.easeOut(duration: 0.6), value: value)
            }
        }
    }
}

// MARK: - Activated strip (compact) -------------------------------------

private struct ActivatedStrip: View {
    @ObservedObject var service: NanoClawService
    @State private var connectorDrawer: String?

    var body: some View {
        DashCard(title: "Activated", icon: "dot.radiowaves.left.and.right", accent: nil) {
            VStack(alignment: .leading, spacing: 8) {
                FlowChips(items: chips)
                HStack(spacing: 16) {
                    Label("provider: \(service.provider)", systemImage: "cpu")
                    if let tick = service.lastTick {
                        Label("last tick \(relative(tick))", systemImage: "clock")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .sheet(item: Binding(
            get: { connectorDrawer.map { ConnectorDrawerItem(id: $0) } },
            set: { connectorDrawer = $0?.id }
        )) { item in
            ConnectorDrawer(id: item.id)
                .environmentObject(service)
        }
    }

    private var chips: [ChipModel] {
        var items: [ChipModel] = []
        items.append(ChipModel(
            id: "mcp",
            label: "MCP",
            detail: service.mcpConnected ? "connected" : (service.mcpError ?? "down"),
            dot: service.mcpConnected ? .green : .red,
            tap: nil
        ))
        for c in service.connectors {
            items.append(ChipModel(
                id: c.id,
                label: c.name,
                detail: c.identity ?? c.status.label,
                dot: dotColor(for: c.status),
                tap: { connectorDrawer = c.id }
            ))
        }
        return items
    }

    private func dotColor(for status: ClawConnectionStatus) -> DashDot {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct ConnectorDrawerItem: Identifiable { let id: String }

// MARK: - Crons card -----------------------------------------------------

private struct CronsCard: View {
    var body: some View {
        DashCard(title: "Crons", icon: "clock.fill", accent: nil) {
            ClawJobsSection()
        }
    }
}

// MARK: - Memory card ----------------------------------------------------

private struct MemoryCard: View {
    var body: some View {
        DashCard(title: "Memory", icon: "brain.head.profile", accent: nil) {
            VStack(alignment: .leading, spacing: 8) {
                MemoryRow(name: "Soul", blurb: "identity, capabilities", tag: "soul")
                MemoryRow(name: "Memory", blurb: "runtime facts · 2200", tag: "memory")
                MemoryRow(name: "User Profile", blurb: "about you · 1375", tag: "profile")
                Divider().padding(.vertical, 2)
                Text("Edit any of these blocks in the Blocks pane to change what the agent knows. Restart the daemon to pick up Soul edits.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MemoryRow: View {
    let name: String
    let blurb: String
    let tag: String
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 0.55, green: 0.40, blue: 0.93))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 11, weight: .medium))
                Text(blurb).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("#\(tag)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

// MARK: - Activity feed --------------------------------------------------

private struct ActivityFeed: View {
    let events: [ActivityEvent]

    var body: some View {
        DashCard(title: "Activity", icon: "waveform", accent: nil) {
            if events.isEmpty {
                Text("waiting for log events …")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                    .onChange(of: events.last?.id) { _, newValue in
                        if let id = newValue {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(id, anchor: .bottom)
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
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 10))
                .foregroundStyle(kind.color)
                .frame(width: 14, alignment: .center)
            Text(Self.timeFormatter.string(from: event.timestamp))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.8))
            Text(event.msg)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            if let extra = event.extra {
                Text(extra)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if event.level >= 40 {
                Circle()
                    .fill(levelColor)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(event.level >= 40 ? levelColor.opacity(0.06) : Color.clear)
        )
    }

    private var kind: EventKind { EventKind.from(event) }

    private var levelColor: Color {
        switch event.level {
        case ..<30: return Color(white: 0.55)
        case 30..<40: return Color(red: 0.18, green: 0.78, blue: 0.46)
        case 40..<50: return Color(red: 0.99, green: 0.78, blue: 0.22)
        default: return Color(red: 0.95, green: 0.32, blue: 0.32)
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
        case .llm: return Color(red: 0.0, green: 0.33, blue: 1.0)
        case .info: return Color(white: 0.55)
        case .error: return Color(red: 0.95, green: 0.32, blue: 0.32)
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

// MARK: - Dashboard primitives ------------------------------------------

private enum DashDot { case green, yellow, red, gray
    var color: Color {
        switch self {
        case .green: return Color(red: 0.18, green: 0.78, blue: 0.46)
        case .yellow: return Color(red: 0.99, green: 0.78, blue: 0.22)
        case .red: return Color(red: 0.95, green: 0.32, blue: 0.32)
        case .gray: return Color(white: 0.55)
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
            Circle()
                .fill(dot.color)
                .frame(width: 6, height: 6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

private struct ChipModel: Identifiable {
    let id: String
    let label: String
    let detail: String
    let dot: DashDot
    let tap: (() -> Void)?
}

private struct FlowChips: View {
    let items: [ChipModel]
    var body: some View {
        let chunked = items.chunked(into: 4)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(chunked.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row) { item in
                        chipView(for: item)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func chipView(for item: ChipModel) -> some View {
        let view = HStack(spacing: 6) {
            PulsingDot(dot: item.dot)
                .frame(width: 12, height: 12)
            Text(item.label).font(.system(size: 11, weight: .medium))
            Text(item.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(item.dot.color.opacity(item.dot.pulses ? 0.30 : 0.06), lineWidth: 0.5)
        )

        if let tap = item.tap {
            Button(action: tap) { view }.buttonStyle(.plain)
        } else {
            view
        }
    }
}

private struct DashCard<Content: View>: View {
    let title: String
    let icon: String
    let accent: Color?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accent ?? .secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .opacity(0.85)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    accent?.opacity(0.25) ?? Color.primary.opacity(0.07),
                    lineWidth: accent != nil ? 0.7 : 0.5
                )
        )
    }
}

private enum GeoColors {
    static let blue = Color(red: 0.0, green: 0.33, blue: 1.0)
    static let blueLight = Color(red: 0.4, green: 0.6, blue: 1.0)
}

// MARK: - Activity feed log tail ----------------------------------------

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
        return home.appendingPathComponent("Library/Logs/GeoClaw/claw.log")
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

// MARK: - Today insights (SQLite/GRDB) ----------------------------------

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
        return home.appendingPathComponent("Library/Application Support/GeoClaw/db/claw.sqlite").path
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
            // Daemon hasn't created the db yet; retry on next refresh() call.
            db = nil
        }
    }

    func refresh() {
        if db == nil { openDb() }
        guard let db else { return }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let startOfDayMs = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)

            do {
                let (perChannel, lastReply) = try await Self.query(db: db, startOfDayMs: startOfDayMs)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.perChannel = perChannel
                    self.totalToday = perChannel.reduce(0) { $0 + $1.count }
                    self.lastReply = lastReply
                    self.todayLabels = self.deriveLabels(from: perChannel)
                }
            } catch {
                // Schema mismatch or io error — fall silent; UI shows empty state.
            }
        }
    }

    nonisolated private static func query(
        db: DatabaseQueue,
        startOfDayMs: Int
    ) async throws -> ([ChannelCount], LastReply?) {
        try await Task.detached(priority: .userInitiated) {
            try db.read { d in
                let rows = try Row.fetchAll(d, sql: """
                    SELECT
                      CASE
                        WHEN instr(channel_id, ':') > 0 THEN substr(channel_id, 1, instr(channel_id, ':') - 1)
                        ELSE channel_id
                      END AS kind,
                      COUNT(*) AS n
                    FROM conversations
                    WHERE ts >= ? AND role = 'user'
                    GROUP BY kind
                    ORDER BY n DESC
                """, arguments: [startOfDayMs])

                let counts: [ChannelCount] = rows.map { r in
                    ChannelCount(kind: r["kind"] ?? "unknown", count: r["n"] ?? 0)
                }

                let lastRow = try Row.fetchOne(d, sql: """
                    SELECT channel_id, content, ts FROM conversations
                    WHERE role = 'assistant' ORDER BY ts DESC LIMIT 1
                """)
                var last: LastReply? = nil
                if let r = lastRow {
                    let cid: String = r["channel_id"] ?? ""
                    let contentJson: String = r["content"] ?? ""
                    let ts: Int64 = r["ts"] ?? 0
                    let kind = String(cid.split(separator: ":").first ?? Substring(cid))
                    last = LastReply(
                        kind: kind,
                        ts: Date(timeIntervalSince1970: Double(ts) / 1000),
                        text: extractText(contentJson)
                    )
                }
                return (counts, last)
            }
        }.value
    }

    private func deriveLabels(from perChannel: [ChannelCount]) -> [String] {
        // Friendly summary chips beneath the bars. Cheap, derived in-memory.
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

// MARK: - Small utils ----------------------------------------------------

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
