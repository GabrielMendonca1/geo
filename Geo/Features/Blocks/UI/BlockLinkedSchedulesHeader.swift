import SwiftUI
import GeoCore

struct BlockLinkedSchedulesHeader: View {
    let blockId: String
    let horizontalPadding: CGFloat

    @Environment(\.appEnvironment) private var appEnvironment

    @State private var linkedTasks: [TaskItem] = []
    @State private var isExpanded: Bool = true

    private let collapseThreshold = 3

    var body: some View {
        Group {
            if !linkedTasks.isEmpty {
                content
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .background(Palette.background)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Palette.border.opacity(0.18))
                            .frame(height: 0.5)
                    }
            }
        }
        .task {
            for await tasks in appEnvironment.tasksRepository.observe() {
                let filtered = tasks
                    .filter { $0.linkedBlockId == blockId }
                    .sorted(by: Self.sortLinkedTasks)
                await MainActor.run {
                    linkedTasks = filtered
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            if isExpanded {
                chipScroll
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.tertiaryForeground)

            Text("Linked schedules")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.foreground.opacity(0.85))

            Text("\(linkedTasks.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.tertiaryForeground)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Palette.secondaryBackground.opacity(0.6)))

            Spacer(minLength: 0)

            if linkedTasks.count > collapseThreshold {
                collapseToggle
            }

            scheduleButton
        }
    }

    private var collapseToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.tertiaryForeground)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Palette.secondaryBackground.opacity(0.5))
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(isExpanded ? "Collapse" : "Expand")
    }

    private var scheduleButton: some View {
        Button(action: openCreateForm) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                Text("Schedule")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Palette.accent.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(Palette.accent.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Schedule this block")
    }

    private var chipScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(linkedTasks) { task in
                    ScheduleChip(task: task) {
                        openTaskForm(taskId: task.id)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func openTaskForm(taskId: String) {
        NotificationCenter.default.post(
            name: .openTaskForm,
            object: nil,
            userInfo: ["taskId": taskId]
        )
    }

    private func openCreateForm() {
        NotificationCenter.default.post(
            name: .openTaskCreateForm,
            object: nil,
            userInfo: ["preFillBlockId": blockId]
        )
    }

    private static func sortLinkedTasks(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if (lhs.status == .pending) != (rhs.status == .pending) {
            return lhs.status == .pending
        }
        let lhsDate = lhs.anchorDate
        let rhsDate = rhs.anchorDate
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

private struct ScheduleChip: View {
    let task: TaskItem
    let onTap: () -> Void

    @State private var isHovering = false

    private var isCompleted: Bool { task.status == .completed }

    private var iconColor: Color {
        if isCompleted { return Palette.tertiaryForeground }
        switch task.kind {
        case .milestone: return Palette.accent
        case .habit: return Color(nsColor: Palette.agentSuccess)
        case .event: return Color(nsColor: Palette.agentWarning)
        case .task: return Palette.accent
        }
    }

    private var titleColor: Color {
        isCompleted ? Palette.tertiaryForeground : Palette.foreground
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: task.kind.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)

                    Text(task.scheduleDisplayLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.tertiaryForeground)
                        .lineLimit(1)
                }

                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Palette.agentSuccess).opacity(0.7))
                } else {
                    Circle()
                        .fill(iconColor.opacity(0.85))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.secondaryBackground.opacity(isHovering ? 0.95 : 0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.border.opacity(isHovering ? 0.4 : 0.2), lineWidth: 0.5)
            )
            .shadow(
                color: Color.black.opacity(isHovering ? 0.12 : 0),
                radius: isHovering ? 4 : 0,
                x: 0,
                y: isHovering ? 2 : 0
            )
            .offset(y: isHovering ? -1 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Open \(task.kind.displayName.lowercased()): \(task.title)")
    }
}
