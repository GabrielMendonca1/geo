import SwiftUI

struct WeeklyReviewSheet: View {
    @EnvironmentObject var coordinator: ReviewCoordinator
    @Environment(\.appEnvironment) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var allTasks: [TaskItem] = []
    @State private var isLoading = true
    @State private var newCommitTitle: String = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isLoading {
                        loadingRow
                    } else {
                        retroSection
                        planSection
                        freeAddSection
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 560)
        .background(
            LinearGradient(
                colors: [Palette.background, Palette.secondaryBackground.opacity(0.2)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .task { await loadTasks() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Week of \(formattedWeekStart)", systemImage: "calendar")
                .font(.system(size: 20, weight: .semibold))
            Text("Weekly review")
                .font(.system(size: 12))
                .foregroundStyle(Palette.tertiaryForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Palette.secondaryBackground.opacity(0.22))
    }

    private var loadingRow: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text("Loading last week...")
                .font(.system(size: 12))
                .foregroundStyle(Palette.tertiaryForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var retroSection: some View {
        ReviewSectionCard(title: "Last week", icon: "arrow.uturn.backward") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Label("\(completedRetro.count) done", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: Palette.agentSuccess))
                    Label("\(pendingRetro.count) open — carry-over or drop?",
                          systemImage: "hourglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.tertiaryForeground)
                }

                if pendingRetro.isEmpty && completedRetro.isEmpty {
                    Text("Nothing committed last week.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiaryForeground)
                } else {
                    VStack(spacing: 6) {
                        ForEach(pendingRetro) { task in
                            retroRow(task)
                        }
                    }
                }
            }
        }
    }

    private func retroRow(_ task: TaskItem) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await complete(task) }
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Palette.tertiaryForeground)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Mark complete")

            Text(task.title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.foreground)
                .lineLimit(1)

            Spacer()

            Button("Carry over") {
                Task { await carryOver(task) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.accent)

            Button("Drop") {
                Task { await drop(task) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.tertiaryForeground)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.background.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Palette.border.opacity(0.15), lineWidth: 1)
        )
    }

    private var planSection: some View {
        ReviewSectionCard(title: "Plan this week", icon: "calendar.badge.plus") {
            VStack(alignment: .leading, spacing: 6) {
                if planCandidates.isEmpty {
                    Text("No long-term items to promote.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiaryForeground)
                } else {
                    ForEach(planCandidates) { task in
                        planRow(task)
                    }
                }
            }
        }
    }

    private func planRow(_ task: TaskItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: task.kind.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.tertiaryForeground)
            Text(task.title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.foreground)
                .lineLimit(1)
            Spacer()
            Button {
                Task { await promoteToWeek(task) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Promote")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Palette.accent.opacity(0.14))
                )
                .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.background.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Palette.border.opacity(0.15), lineWidth: 1)
        )
    }

    private var freeAddSection: some View {
        ReviewSectionCard(title: "New commit", icon: "plus.circle") {
            HStack(spacing: 8) {
                TextField("Add commit for this week...", text: $newCommitTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await createCommit() } }
                Button {
                    Task { await createCommit() }
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                    }
                }
                .buttonStyle(.plain)
                .disabled(trimmedNewCommit.isEmpty || isCreating)
                .foregroundStyle(trimmedNewCommit.isEmpty ? Palette.tertiaryForeground : Palette.accent)
                .pointingHandCursor()
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Later") { coordinator.dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Done") {
                let weekStart = coordinator.previousWeekStart()
                coordinator.markWeeklyReviewed()
                dismiss()
                Task { @MainActor in
                    _ = await WeeklyLogService.ensureLog(
                        for: weekStart,
                        environment: env,
                        blocksStore: AppContainer.live.blocksStore,
                        tasksStore: AppContainer.live.tasksStore,
                        tagsStore: AppContainer.live.tagStore
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Palette.secondaryBackground.opacity(0.22))
    }

    private var completedRetro: [TaskItem] {
        allTasks.filter {
            $0.horizon == .week
                && $0.status == .completed
                && coordinator.isInPreviousWeek($0.modifiedAt)
        }
    }

    private var pendingRetro: [TaskItem] {
        allTasks.filter {
            $0.horizon == .week
                && $0.status == .pending
                && coordinator.isInPreviousWeek($0.modifiedAt)
        }
    }

    private var planCandidates: [TaskItem] {
        allTasks
            .filter { $0.horizon == .month && $0.status == .pending }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var trimmedNewCommit: String {
        newCommitTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var formattedWeekStart: String {
        DateFormatters.monthDay.string(from: coordinator.currentWeekStart())
    }

    private func loadTasks() async {
        isLoading = true
        defer { isLoading = false }
        do {
            allTasks = try await env.tasksRepository.list()
        } catch {
            errorMessage = "Could not load tasks: \(error.localizedDescription)"
        }
    }

    private func complete(_ task: TaskItem) async {
        var updated = task
        updated.status = .completed
        updated.modifiedAt = Date()
        await applyUpdate(updated)
    }

    private func carryOver(_ task: TaskItem) async {
        var updated = task
        updated.modifiedAt = Date()
        await applyUpdate(updated)
    }

    private func drop(_ task: TaskItem) async {
        var updated = task
        updated.horizon = .none
        updated.modifiedAt = Date()
        await applyUpdate(updated)
    }

    private func promoteToWeek(_ task: TaskItem) async {
        var updated = task
        updated.horizon = .week
        updated.modifiedAt = Date()
        await applyUpdate(updated)
    }

    private func applyUpdate(_ task: TaskItem) async {
        do {
            try await env.tasksRepository.update(task)
            await loadTasks()
        } catch {
            errorMessage = "Update failed: \(error.localizedDescription)"
        }
    }

    private func createCommit() async {
        let title = trimmedNewCommit
        guard !title.isEmpty, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        let draft = TaskDraft(
            title: title,
            startTime: Calendar.current.startOfDay(for: Date()),
            kind: .task,
            horizon: .week
        )
        do {
            _ = try await env.tasksRepository.create(draft)
            newCommitTitle = ""
            await loadTasks()
        } catch {
            errorMessage = "Could not create: \(error.localizedDescription)"
        }
    }
}

struct ReviewSectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Palette.background.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Palette.border.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 1)
    }
}
