import SwiftUI

struct NanoToolCallGroupView: View {
    let calls: [NanoToolCall]
    @State private var expanded: Bool = false
    @State private var tick: Date = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
            header
            if expanded {
                VStack(spacing: 6) {
                    ForEach(calls) { call in
                        NanoCardRenderer(call: call)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onReceive(timer) { now in
            // Tick only while any call is still running, to avoid wasted work.
            if calls.contains(where: { $0.status == .running }) {
                tick = now
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                statusGlyph
                    .frame(width: 14, height: 14)

                Text(headlineText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                if let elapsed = visibleElapsed {
                    Text("· \(elapsed)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.7))
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch overallStatus {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.65)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.20, green: 0.78, blue: 0.46))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.95, green: 0.32, blue: 0.32))
        }
    }

    private var overallStatus: NanoToolCall.Status {
        if calls.contains(where: { $0.status == .failed }) { return .failed }
        if calls.contains(where: { $0.status == .running }) { return .running }
        return .done
    }

    private var headlineText: String {
        if calls.count == 1 {
            return prettyToolName(calls[0].name)
        }
        let verb: String
        switch overallStatus {
        case .running: verb = "Running"
        case .done: verb = "Used"
        case .failed: verb = "Failed"
        }
        return "\(verb) \(calls.count) tools"
    }

    /// Claude Desktop pattern: hide the timer for fast calls; show it only past 5s.
    private var visibleElapsed: String? {
        let total = calls.reduce(0.0) { acc, call in acc + call.elapsedSeconds }
        guard total >= 5 else { return nil }
        if total < 60 { return String(format: "%.1fs", total) }
        let minutes = Int(total / 60)
        let secs = Int(total) % 60
        return "\(minutes)m \(secs)s"
    }
}

struct NanoCardRenderer: View {
    let call: NanoToolCall

    var body: some View {
        if let kind = nativeKind {
            NanoNativeCard(for: kind)
        } else {
            genericCard
        }
    }

    private var nativeKind: NanoNativeCardKind? {
        let lower = call.name.lowercased()
        let isDispatch = lower.contains("dispatch_subagent") || lower.contains("dispatch_agent")
        if isDispatch { return NanoNativeCardKind.from(call: call) }
        if call.status == .done { return NanoNativeCardKind.from(call: call) }
        return nil
    }

    private var genericCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14, height: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(prettyToolName(call.name))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                    statusDot
                    Spacer(minLength: 0)
                }
                if let detail = inputDetail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let result = resultPreview {
                    Text(result)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(call.isError ? Color(red: 0.95, green: 0.32, blue: 0.32) : .secondary)
                        .lineLimit(6)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var icon: String {
        let n = call.name.lowercased()
        if n.contains("day") || n.contains("today") { return "calendar" }
        if n.contains("task") { return "checkmark.circle" }
        if n.contains("block") || n.contains("note") { return "doc.text" }
        if n.contains("tag") { return "tag" }
        if n.contains("conversation") || n.contains("history") { return "bubble.left.and.bubble.right" }
        if n.contains("whatsapp") { return "phone.bubble.left" }
        if n.contains("search") { return "magnifyingglass" }
        if n.contains("dispatch") { return "sparkle" }
        return "wrench.adjustable"
    }

    private var tint: Color {
        let n = call.name.lowercased()
        if call.isError { return Color(red: 0.95, green: 0.32, blue: 0.32) }
        if n.contains("day") { return Color(red: 0.95, green: 0.62, blue: 0.10) }
        if n.contains("task") { return Color(red: 0.20, green: 0.78, blue: 0.46) }
        if n.contains("block") { return Color(red: 0.0, green: 0.33, blue: 1.0) }
        if n.contains("tag") { return Color(red: 0.55, green: 0.40, blue: 0.93) }
        return Color(white: 0.5)
    }

    @ViewBuilder private var statusDot: some View {
        switch call.status {
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.5)
        case .done:
            Circle().fill(Color(red: 0.20, green: 0.78, blue: 0.46)).frame(width: 5, height: 5)
        case .failed:
            Circle().fill(Color(red: 0.95, green: 0.32, blue: 0.32)).frame(width: 5, height: 5)
        }
    }

    private var inputDetail: String? {
        guard case .object(let obj) = call.input else { return nil }
        let preferredKeys = ["title", "query", "id", "channelId", "name", "tag", "date", "text"]
        for key in preferredKeys {
            if case .string(let s) = obj[key], !s.isEmpty {
                return "\(key): \(s)"
            }
        }
        if let firstString = obj.values.compactMap({ $0.stringValue }).first {
            return firstString
        }
        return nil
    }

    /// First ~6 lines, monospaced. Claude Desktop pattern.
    private var resultPreview: String? {
        guard let result = call.result else { return call.isError ? "failed" : nil }
        let raw: String = {
            if let s = result.stringValue { return s }
            if case .array(let items) = result {
                let strings = items.compactMap { $0.stringValue }
                if !strings.isEmpty { return strings.prefix(6).joined(separator: "\n") }
                return "\(items.count) result\(items.count == 1 ? "" : "s")"
            }
            if case .object(let obj) = result {
                for key in ["title", "summary", "text", "reply"] {
                    if case .string(let s) = obj[key] { return s }
                }
                return "\(obj.count) field\(obj.count == 1 ? "" : "s")"
            }
            return ""
        }()
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).prefix(6)
        return lines.joined(separator: "\n")
    }
}

private func prettyToolName(_ raw: String) -> String {
    // Strip MCP server prefix (`mcp__geo__`, `geo.`, `mcp_geo_`)
    var name = raw
    for prefix in ["mcp__", "mcp_"] {
        if name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
    }
    let parts = name.split(whereSeparator: { $0 == "_" || $0 == "." })
    let kept = parts.suffix(3).joined(separator: "_")
    return kept
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: ".", with: " ")
}
