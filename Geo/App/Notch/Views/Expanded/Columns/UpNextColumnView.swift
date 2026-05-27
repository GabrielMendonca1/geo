import SwiftUI

struct UpNextColumnView: View {
    @Environment(\.appEnvironment) private var env
    @State private var tasks: [TaskItem] = []

    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f
    }()
    private static var dayLabel: String { dayLabelFormatter.string(from: Date()) }

    private static var timeFormatter: DateFormatter { DateFormatters.shortTime }

    private static let accentPalette: [Color] = [
        Color(red: 0.95, green: 0.3, blue: 0.4),
        Color(red: 0.6, green: 0.35, blue: 0.95),
        Color(red: 0.2, green: 0.75, blue: 0.7),
        Color(red: 0.95, green: 0.65, blue: 0.2),
        Color(red: 0.25, green: 0.5, blue: 0.95)
    ]

    private func accentColor(for task: TaskItem) -> Color {
        switch task.priority {
        case .urgent:  return Color(red: 0.95, green: 0.3, blue: 0.4)
        case .high:    return Color(red: 0.95, green: 0.55, blue: 0.2)
        case .medium:  return Color(red: 0.95, green: 0.85, blue: 0.25)
        case .low:     return Color(red: 0.25, green: 0.5, blue: 0.95)
        case .unset:   return Self.accentPalette[abs(task.id.hashValue) % Self.accentPalette.count]
        }
    }

    private var feed: [TaskItem] {
        let now = Date()
        let window = now.addingTimeInterval(48 * 3600)
        return tasks
            .filter { $0.status == .pending }
            .filter { $0.anchorDate <= window || $0.isOverdue }
            .sorted { lhs, rhs in
                if lhs.isOverdue != rhs.isOverdue { return lhs.isOverdue }
                return lhs.anchorDate < rhs.anchorDate
            }
    }

    private func groupedFeed(_ items: [TaskItem]) -> [(label: String, items: [TaskItem])] {
        let cal = Calendar.current
        var overdue: [TaskItem] = []
        var today: [TaskItem] = []
        var tomorrow: [TaskItem] = []
        for item in items {
            if item.isOverdue { overdue.append(item) }
            else if cal.isDateInToday(item.anchorDate) { today.append(item) }
            else { tomorrow.append(item) }
        }
        var groups: [(String, [TaskItem])] = []
        if !overdue.isEmpty  { groups.append(("OVERDUE", overdue)) }
        if !today.isEmpty    { groups.append(("TODAY", today)) }
        if !tomorrow.isEmpty { groups.append(("TOMORROW", tomorrow)) }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            ColumnSectionHeader("Up Next", icon: "calendar.badge.clock") {
                Text(Self.dayLabel)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.tertiaryForeground)
            }

            let items = feed
            if items.isEmpty {
                Spacer()
                VStack(spacing: 3) {
                    Text("No upcoming")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiaryForeground)
                    Text("Nothing scheduled")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiaryForeground.opacity(0.7))
                }
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        let groups = groupedFeed(items)
                        ForEach(Array(groups.enumerated()), id: \.offset) { idx, group in
                            if idx > 0 { daySeparator(group.label) }
                            ForEach(group.items) { task in taskRow(task) }
                        }
                    }
                }
            }
        }
        .task {
            for await t in env.tasksRepository.observe() {
                await MainActor.run { tasks = t }
            }
        }
    }

    private func daySeparator(_ label: String) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(Palette.border.opacity(0.2)).frame(height: 0.5)
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Palette.tertiaryForeground.opacity(0.7))
                .fixedSize()
            Rectangle().fill(Palette.border.opacity(0.2)).frame(height: 0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func timeOrMilestoneLabel(_ task: TaskItem) -> some View {
        if task.kind == .milestone {
            let d = task.daysUntilMilestone ?? 0
            let label = d == 0 ? "Today" : d > 0 ? "\(d)d away" : "\(abs(d))d overdue"
            HStack(spacing: 3) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(accentColor(for: task))
                Text(label)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.tertiaryForeground)
            }
        } else if case .event(let start, let end) = task.body {
            Text("\(Self.timeFormatter.string(from: start)) – \(Self.timeFormatter.string(from: end))")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.tertiaryForeground)
        } else {
            Text(Self.timeFormatter.string(from: task.anchorDate))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.tertiaryForeground)
        }
    }

    private var overdueBadge: some View {
        Text("OVERDUE")
            .font(.system(size: 8, weight: .medium))
            .tracking(1)
            .foregroundStyle(Palette.tertiaryForeground)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Palette.border.opacity(0.2))
            .clipShape(Capsule())
    }

    private func taskRow(_ task: TaskItem) -> some View {
        Button { MenuActions.openTaskForm(taskId: task.id, environment: env) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accentColor(for: task))
                    .frame(width: 2.5, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 4) {
                        timeOrMilestoneLabel(task)
                        if task.isOverdue { overdueBadge }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
