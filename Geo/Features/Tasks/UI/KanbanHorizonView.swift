import SwiftUI

struct KanbanHorizonView: View {
    @Environment(\.appEnvironment) private var env
    @EnvironmentObject private var blocksStore: BlocksStore
    @State private var tasks: [TaskItem] = []

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            HorizonColumn(
                horizon: .day,
                title: TaskHorizon.day.displayName,
                tasks: tasksFor(.day),
                progressProvider: progress(for:),
                onDrop: { handleDrop(ids: $0, to: .day) }
            )
            HorizonColumn(
                horizon: .week,
                title: TaskHorizon.week.displayName,
                tasks: tasksFor(.week),
                progressProvider: progress(for:),
                onDrop: { handleDrop(ids: $0, to: .week) }
            )
            HorizonColumn(
                horizon: .month,
                title: TaskHorizon.month.displayName,
                tasks: tasksFor(.month),
                progressProvider: progress(for:),
                onDrop: { handleDrop(ids: $0, to: .month) }
            )
        }
        .padding()
        .task {
            for await updated in env.tasksRepository.observe() {
                await MainActor.run { tasks = updated }
            }
        }
    }

    private func progress(for task: TaskItem) -> MilestoneProgress? {
        task.milestoneProgress(blocks: blocksStore, allTasks: tasks)
    }

    private func tasksFor(_ horizon: TaskHorizon) -> [TaskItem] {
        tasks
            .filter { $0.status == .pending && $0.horizon == horizon }
            .sorted { lhs, rhs in
                if lhs.orderIndex != rhs.orderIndex {
                    return lhs.orderIndex < rhs.orderIndex
                }
                return lhs.startTime < rhs.startTime
            }
    }

    private func handleDrop(ids: [String], to horizon: TaskHorizon) {
        Task {
            for id in ids {
                guard var task = tasks.first(where: { $0.id == id }) else { continue }
                guard task.horizon != horizon else { continue }
                task.horizon = horizon
                task.modifiedAt = Date()
                try? await env.tasksRepository.update(task)
            }
        }
    }
}

struct HorizonColumn: View {
    let horizon: TaskHorizon
    let title: String
    let tasks: [TaskItem]
    var progressProvider: (TaskItem) -> MilestoneProgress? = { _ in nil }
    var onDrop: (([String]) -> Void)?

    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if tasks.isEmpty {
                        emptyState
                    } else {
                        ForEach(tasks) { task in
                            HorizonTaskCard(task: task, progress: progressProvider(task))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: .infinity, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.primary.opacity(0.35) : Color.primary.opacity(0.08),
                    lineWidth: isTargeted ? 1.5 : 1
                )
        )
        .dropDestination(for: String.self) { ids, _ in
            onDrop?(ids)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            Text("\(tasks.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(.quaternary)
                )
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private var emptyState: some View {
        Text("No tasks")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }
}

struct HorizonTaskCard: View {
    let task: TaskItem
    var progress: MilestoneProgress? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.kind.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let timeLabel = todayTimeLabel {
                        Label(timeLabel, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }

                    if task.priority != .unset {
                        priorityPill
                    }
                }

                if task.kind == .milestone, let progress {
                    MilestoneProgressBar(progress: progress, compact: false)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .draggable(task.id)
    }

    private var todayTimeLabel: String? {
        guard Calendar.current.isDateInToday(task.startTime) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: task.startTime)
    }

    private var priorityPill: some View {
        HStack(spacing: 3) {
            Image(systemName: task.priority.icon)
                .font(.system(size: 9, weight: .bold))
            Text(task.priority.displayName)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(.quaternary)
        )
    }
}
