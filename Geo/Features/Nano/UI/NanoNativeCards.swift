import SwiftUI

private let geoBlue = Color(red: 0.0, green: 0.33, blue: 1.0)

// MARK: - Block card

struct NanoBlockCardView: View {
    let blockId: String
    @EnvironmentObject private var blocksStore: BlocksStore

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
    }
}

// MARK: - Task card

struct NanoTaskCardView: View {
    let taskId: String
    @EnvironmentObject private var tasksStore: TasksStore

    var body: some View {
        let task = tasksStore.tasks.first(where: { $0.id == taskId })
        cardContainer {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: statusIcon(task?.status))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor(task?.status))
                    .frame(width: 16, height: 16)
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

    /// Returns nil if the tool call doesn't produce a card we know how to render natively.
    static func from(call: NanoToolCall) -> NanoNativeCardKind? {
        let name = call.name.lowercased()
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
}

@ViewBuilder
func NanoNativeCard(for kind: NanoNativeCardKind) -> some View {
    switch kind {
    case .block(let id): NanoBlockCardView(blockId: id)
    case .task(let id): NanoTaskCardView(taskId: id)
    case .day(let id): NanoDayCardView(dayId: id)
    }
}
