import SwiftUI
import AppKit

private let geoBlue = Color(red: 0.0, green: 0.33, blue: 1.0)

// MARK: - Block card

struct NanoBlockCardView: View {
    let blockId: String
    var onTap: (() -> Void)? = nil
    @EnvironmentObject private var blocksStore: BlocksStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let block = blocksStore.blocks.first(where: { $0.id == blockId })
        cardContainer {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(geoBlue)
                    .frame(width: 16, height: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(block?.title ?? blockId)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let block {
                        Text(block.markdown.prefix(140))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("Block not in local store").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let date = block?.lastEdited {
                        Text(relativeShort(date))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let onTap { onTap() }
            else { MenuActions.openBlockEditor(blockId, openWindow: openWindow) }
        }
    }
}

// MARK: - Task card

struct NanoTaskCardView: View {
    let taskId: String
    var interactive: Bool = true
    var onToggle: ((String, TaskStatus) -> Void)? = nil
    @EnvironmentObject private var tasksStore: TasksStore

    var body: some View {
        let task = tasksStore.tasks.first(where: { $0.id == taskId })
        cardContainer {
            HStack(alignment: .center, spacing: 10) {
                checkbox(task: task)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task?.title ?? taskId)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .strikethrough(task?.status == .completed)
                        .lineLimit(1)
                    if let task {
                        Text(taskSubtitle(task))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Task not in local store").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func checkbox(task: TaskItem?) -> some View {
        let status = task?.status
        let icon = statusIcon(status)
        let color = statusColor(status)
        if interactive, let task {
            Button {
                toggle(task)
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.status == .completed ? "Mark pending" : "Mark completed")
        } else {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16, height: 16)
        }
    }

    private func toggle(_ task: TaskItem) {
        var updated = task
        let next: TaskStatus = task.status == .completed ? .pending : .completed
        updated.status = next
        tasksStore.replaceTask(updated)
        onToggle?(task.id, next)
    }

    private func statusIcon(_ status: TaskStatus?) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .pending: return "circle"
        case .none: return "circle.dashed"
        }
    }

    private func statusColor(_ status: TaskStatus?) -> Color {
        switch status {
        case .completed: return Color(red: 0.20, green: 0.78, blue: 0.46)
        case .pending: return geoBlue
        case .none: return Color.secondary
        }
    }

    private func taskSubtitle(_ task: TaskItem) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d, HH:mm"
        return df.string(from: task.startTime)
    }
}

// MARK: - Day card

struct NanoDayCardView: View {
    let dayId: String?
    @EnvironmentObject private var dayStore: DayStore

    var body: some View {
        let day = dayStore.days.first(where: { $0.id == (dayId ?? todayId) })
        cardContainer {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.10))
                    .frame(width: 16, height: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(day != nil ? humanDay(day!.id) : "Today")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    if day == nil {
                        Text("No day record")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var todayId: String {
        DateFormatters.dayId.string(from: Date())
    }

    private func humanDay(_ id: String) -> String {
        guard let date = DateFormatters.dayId.date(from: id) else { return id }
        let df = DateFormatter()
        df.dateStyle = .full
        return df.string(from: date)
    }
}

// MARK: - Tag pill

struct TagPill: View {
    let tag: Tag

    var body: some View {
        Text(tag.name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(geoBlue)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(geoBlue.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct NanoTagPillsView: View {
    let tags: [Tag]

    var body: some View {
        if tags.isEmpty {
            Text("No tags")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ForEach(tags, id: \.id) { tag in
                    TagPill(tag: tag)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Agent dispatch card

struct AgentDispatchCard: View {
    let call: NanoToolCall
    var onStop: ((String) -> Void)? = nil

    enum DispatchStatus {
        case queued, running, done, failed

        var label: String {
            switch self {
            case .queued: return "queued"
            case .running: return "running"
            case .done: return "done"
            case .failed: return "failed"
            }
        }

        var color: Color {
            switch self {
            case .queued: return Color.secondary
            case .running: return Color(red: 0.0, green: 0.33, blue: 1.0)
            case .done: return Color(red: 0.20, green: 0.78, blue: 0.46)
            case .failed: return Color(red: 0.95, green: 0.32, blue: 0.32)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let workspace = workspacePath {
                Text(workspace)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !tailLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(tailLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .lineLimit(4)
            }
            actionRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: Palette.agentCard))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: Palette.agentBorder), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 16, height: 16)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            statusPill
        }
    }

    private var statusPill: some View {
        let status = dispatchStatus
        return HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 5, height: 5)
            Text(status.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(status.color.opacity(0.12))
        )
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                openWorkspace()
            } label: {
                Label("Open Workspace", systemImage: "folder")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(workspacePath == nil)
            .opacity(workspacePath == nil ? 0.5 : 1)

            Button {
                if let id = dispatchId { onStop?(id) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.95, green: 0.32, blue: 0.32))
            }
            .buttonStyle(.plain)
            .disabled(dispatchStatus != .running || dispatchId == nil)
            .opacity(dispatchStatus == .running && dispatchId != nil ? 1 : 0.5)
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        let prompt: String? = {
            if case .object(let obj) = call.input,
               let v = obj["prompt"],
               case .string(let s) = v { return s }
            return nil
        }()
        let firstLine = (prompt ?? prettyName(call.name))
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
            ?? call.name
        if firstLine.count <= 60 { return firstLine }
        let idx = firstLine.index(firstLine.startIndex, offsetBy: 60)
        return String(firstLine[..<idx])
    }

    private var workspacePath: String? {
        stringField("workspace_path")
    }

    private var dispatchId: String? {
        stringField("dispatch_id")
    }

    private var tailLines: [String] {
        guard let partial = call.partialResult,
              case .object(let obj) = partial,
              let tail = obj["tail"],
              case .array(let arr) = tail else { return [] }
        let strings = arr.compactMap { $0.stringValue }
        return Array(strings.suffix(4))
    }

    private func stringField(_ key: String) -> String? {
        if let result = call.result,
           case .object(let obj) = result,
           let v = obj[key],
           case .string(let s) = v,
           !s.isEmpty { return s }
        if let partial = call.partialResult,
           case .object(let obj) = partial,
           let v = obj[key],
           case .string(let s) = v,
           !s.isEmpty { return s }
        return nil
    }

    private var dispatchStatus: DispatchStatus {
        if call.isError { return .failed }
        if call.result != nil { return .done }
        if call.partialResult != nil { return .running }
        return .queued
    }

    private func openWorkspace() {
        guard let path = workspacePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func prettyName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - Shared chrome

@ViewBuilder
private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
}

private func relativeShort(_ date: Date) -> String {
    let interval = -date.timeIntervalSinceNow
    if interval < 60 { return "just now" }
    if interval < 3600 { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    return "\(Int(interval / 86400))d ago"
}

// MARK: - Dispatch helpers

enum NanoNativeCardKind {
    case block(id: String)
    case task(id: String)
    case day(id: String?)
    case tag(tags: [Tag])
    case agentDispatch(call: NanoToolCall)

    static func from(call: NanoToolCall) -> NanoNativeCardKind? {
        let name = call.name.lowercased()
        if name.contains("dispatch_subagent") || name.contains("ai_dispatch_agent") || name.contains("dispatch_agent") {
            return .agentDispatch(call: call)
        }
        if name.contains("list_tags") || name.contains("set_block_tag") {
            return .tag(tags: extractTags(call: call))
        }
        if name.contains("get_block") || name.contains("get_block_by_title") {
            if let id = extractId(call.result, keys: ["id"]) { return .block(id: id) }
        }
        if name.contains("get_task") {
            if let id = extractId(call.result, keys: ["id"]) { return .task(id: id) }
        }
        if name.contains("get_today") || name.contains("get_day") {
            return .day(id: extractId(call.result, keys: ["id", "day_id"]))
        }
        return nil
    }

    private static func extractId(_ value: JSONValue?, keys: [String]) -> String? {
        guard let value, case .object(let obj) = value else { return nil }
        for key in keys {
            if case .string(let s) = obj[key], !s.isEmpty { return s }
        }
        return nil
    }

    private static func extractTags(call: NanoToolCall) -> [Tag] {
        guard let result = call.result else { return [] }
        var raw: [JSONValue] = []
        switch result {
        case .array(let arr):
            raw = arr
        case .object(let obj):
            if let nested = obj["tags"], case .array(let arr) = nested {
                raw = arr
            } else {
                raw = [result]
            }
        default:
            return []
        }
        return raw.compactMap(decodeTag)
    }

    private static func decodeTag(_ value: JSONValue) -> Tag? {
        guard case .object(let obj) = value,
              let idValue = obj["id"], case .string(let id) = idValue,
              let nameValue = obj["name"], case .string(let name) = nameValue
        else { return nil }
        let color: TagColor
        if let colorValue = obj["color"], case .object(let c) = colorValue {
            color = TagColor(
                red: c["red"]?.doubleValue ?? 0.0,
                green: c["green"]?.doubleValue ?? 0.33,
                blue: c["blue"]?.doubleValue ?? 1.0,
                alpha: c["alpha"]?.doubleValue ?? 1.0
            )
        } else {
            color = TagColor(red: 0.0, green: 0.33, blue: 1.0)
        }
        return Tag(id: id, name: name, color: color)
    }
}

@ViewBuilder
func NanoNativeCard(for kind: NanoNativeCardKind) -> some View {
    switch kind {
    case .block(let id): NanoBlockCardView(blockId: id)
    case .task(let id): NanoTaskCardView(taskId: id)
    case .day(let id): NanoDayCardView(dayId: id)
    case .tag(let tags): NanoTagPillsView(tags: tags)
    case .agentDispatch(let call): AgentDispatchCard(call: call)
    }
}

private extension JSONValue {
    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}
