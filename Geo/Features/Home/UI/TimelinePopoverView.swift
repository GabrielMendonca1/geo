import SwiftUI

struct TimelinePopoverView: View {
    let date: Date
    let tasks: [TaskItem]
    let blocks: [BlockEntity]
    let captures: [CaptureItem]

    private var entries: [TimelineEntry] {
        let taskEntries = tasks.map { task in
            TimelineEntry(id: "task-\(task.id)", date: task.startTime, kind: .task(task))
        }
        let blockEntries = blocks.map { block in
            TimelineEntry(id: "block-\(block.id)", date: block.date, kind: .block(block))
        }
        let captureEntries = captures.map { capture in
            TimelineEntry(id: "capture-\(capture.id.uuidString)", date: capture.timestamp, kind: .capture(capture))
        }
        return (taskEntries + blockEntries + captureEntries).sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(date.formatted(date: .long, time: .omitted))
                .font(.system(size: 14, weight: .semibold))

            if entries.isEmpty {
                Text("No activity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.tertiaryForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            TimelineRow(entry: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

private struct TimelineEntry: Identifiable {
    enum Kind {
        case task(TaskItem)
        case block(BlockEntity)
        case capture(CaptureItem)
    }

    let id: String
    let date: Date
    let kind: Kind
}

private struct TimelineRow: View {
    let entry: TimelineEntry

    private static var timeFormatter: DateFormatter { DateFormatters.shortTime }

    private var title: String {
        switch entry.kind {
        case .task(let task):
            return task.title
        case .block(let block):
            return block.displayTitle
        case .capture(let capture):
            return capture.fileName
        }
    }

    private var subtitle: String {
        switch entry.kind {
        case .task(let task):
            return taskTimeText(task)
        case .block(let block):
            return timeText(block.date)
        case .capture(let capture):
            return timeText(capture.timestamp)
        }
    }

    private var detail: String? {
        switch entry.kind {
        case .task(let task):
            return task.status == .completed ? "Completed" : "Pending"
        case .block:
            return nil
        case .capture(let capture):
            guard let text = capture.extractedText, !text.isEmpty else { return nil }
            return text
        }
    }

    private var indicatorColor: Color {
        switch entry.kind {
        case .task:
            return Palette.accent
        case .block:
            return Palette.foreground
        case .capture:
            return Palette.tertiaryForeground
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiaryForeground)
                    .lineLimit(1)

                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.tertiaryForeground)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeText(_ date: Date) -> String {
        TimelineRow.timeFormatter.string(from: date)
    }

    private func taskTimeText(_ task: TaskItem) -> String {
        if let endTime = task.endTime {
            return "\(timeText(task.startTime))–\(timeText(endTime))"
        }
        return timeText(task.startTime)
    }

}
