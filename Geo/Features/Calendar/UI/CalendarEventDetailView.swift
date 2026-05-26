import SwiftUI

struct CalendarEventDetailView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    let event: CalendarEvent
    let onDismiss: () -> Void
    let onEdit: (TaskItem) -> Void
    let onStatusToggled: ((CalendarEvent) -> Void)?

    private static var timeFormatter: DateFormatter { DateFormatters.shortTime }

    private static var dateFormatter: DateFormatter { DateFormatters.mediumDate }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Details")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.tertiaryForeground)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.tertiaryForeground)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            switch event.type {
            case let .task(task):
                taskDetail(task)
            case let .holiday(holiday):
                holidayDetail(holiday)
            case .block:
                EmptyView()
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func taskDetail(_ task: TaskItem) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(event.color)
                .frame(width: 8, height: 8)
            Text(task.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.foreground)
                .lineLimit(2)
        }

        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 11))
            Text(timeRange(start: task.startTime, end: task.endTime))
                .font(.system(size: 12))
        }
        .foregroundStyle(Palette.tertiaryForeground)

        statusBadge(task.status)

        if !task.notes.isEmpty {
            Text(task.notes)
                .font(.system(size: 12))
                .foregroundStyle(Palette.foreground.opacity(0.7))
                .lineLimit(3)
        }

        HStack(spacing: 6) {
            Button {
                toggleComplete(task)
            } label: {
                Label(
                    task.status == .completed ? "Mark Pending" : "Complete",
                    systemImage: task.status == .completed ? "arrow.uturn.backward" : "checkmark"
                )
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                onEdit(task)
            } label: {
                Label("Edit", systemImage: "pencil")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func holidayDetail(_ holiday: Holiday) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(event.color)
                .frame(width: 8, height: 8)
            Text(holiday.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.foreground)
        }

        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 11))
            if let endDate = holiday.endDate, !Calendar.current.isDate(holiday.startDate, inSameDayAs: endDate) {
                Text("\(Self.dateFormatter.string(from: holiday.startDate)) – \(Self.dateFormatter.string(from: endDate))")
                    .font(.system(size: 12))
            } else {
                Text(Self.dateFormatter.string(from: holiday.startDate))
                    .font(.system(size: 12))
            }
        }
        .foregroundStyle(Palette.tertiaryForeground)
    }

    private func statusBadge(_ status: TaskStatus) -> some View {
        Text(status == .completed ? "Completed" : "Pending")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(status == .completed ? Color(nsColor: Palette.agentSuccess) : Palette.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(
                        (status == .completed ? Color(nsColor: Palette.agentSuccess) : Palette.accent)
                            .opacity(0.14)
                    )
            )
    }

    private func timeRange(start: Date, end: Date?) -> String {
        let s = Self.timeFormatter.string(from: start)
        if let end {
            return "\(s) – \(Self.timeFormatter.string(from: end))"
        }
        return s
    }

    private func toggleComplete(_ task: TaskItem) {
        var updated = task
        updated.status = task.status == .completed ? .pending : .completed
        updated.modifiedAt = Date()
        let newEvent = CalendarEvent(
            id: event.id,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            type: .task(updated),
            color: event.color
        )
        onStatusToggled?(newEvent)
        Task {
            try? await appEnvironment.tasksRepository.update(updated)
        }
    }
}
