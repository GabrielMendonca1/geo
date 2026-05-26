import SwiftUI

struct DailyReviewSheet: View {
    @EnvironmentObject var coordinator: ReviewCoordinator
    @Environment(\.appEnvironment) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var allTasks: [TaskItem] = []
    @State private var isLoading = true
    @State private var newTitle: String = ""
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
                        carryOverSection
                        suggestionsSection
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
            Label("Today — \(formattedToday)", systemImage: "sun.max")
                .font(.system(size: 20, weight: .semibold))
            Text("Daily review")
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
            Text("Loading today's plan...")
                .font(.system(size: 12))
                .foregroundStyle(Palette.tertiaryForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var carryOverSection: some View {
        ReviewSectionCard(title: "Yesterday's unfinished", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 6) {
                if carryOverTasks.isEmpty {
                    Text("Clean slate.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiaryForeground)
                } else {
                    ForEach(carryOverTasks) { task in
                        carryOverRow(task)
                    }
                }
            }
        }
    }

    private func carryOverRow(_ task: TaskItem) -> some View {
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
                Task { await recommitToday(task) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Re-commit")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Palette.accent.opacity(0.14)))
                .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

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

    private var suggestionsSection: some View {
        ReviewSectionCard(title: "From this week", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 6) {
                if weeklySuggestions.isEmpty {
                    Text("Nothing staged from the weekly plan.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiaryForeground)
                } else {
                    ForEach(weeklySuggestions) { task in
                        suggestionRow(task)
                    }
                }
            }
        }
    }

    private func suggestionRow(_ task: TaskItem) -> some View {
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
                Task { await doToday(task) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Do today")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Palette.accent.opacity(0.14)))
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
        ReviewSectionCard(title: "New for today", icon: "plus.circle") {
            HStack(spacing: 8) {
                TextField("Add for today...", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await createForToday() } }
                Button {
                    Task { await createForToday() }
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                    }
                }
                .buttonStyle(.plain)
                .disabled(trimmedNew.isEmpty || isCreating)
                .foregroundStyle(trimmedNew.isEmpty ? Palette.tertiaryForeground : Palette.accent)
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
                coordinator.markDailyReviewed()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Palette.secondaryBackground.opacity(0.22))
    }

    private var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var nineAMToday: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private var carryOverTasks: [TaskItem] {
        allTasks.filter {
            $0.horizon == .day
                && $0.status == .pending
                && $0.startTime < startOfToday
                && !$0.recurrence.isRepeating
        }
    }

    private var weeklySuggestions: [TaskItem] {
        allTasks.filter {
            guard $0.horizon == .week, $0.status == .pending else { return false }
            return !Calendar.current.isDate($0.startTime, inSameDayAs: Date())
        }
    }

    private var trimmedNew: String {
        newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var formattedToday: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: Date())
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

    private func recommitToday(_ task: TaskItem) async {
        var updated = task
        updated.horizon = .day
        updated.startTime = nineAMToday
        updated.modifiedAt = Date()
        await applyUpdate(updated)
    }

    private func drop(_ task: TaskItem) async {
        var updated = task
        updated.horizon = .none
        updated.modifiedAt = Date()
        await applyUpdate(updated)
    }

    private func doToday(_ task: TaskItem) async {
        var updated = task
        updated.horizon = .day
        if !Calendar.current.isDate(task.startTime, inSameDayAs: Date()) {
            updated.startTime = nineAMToday
        }
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

    private func createForToday() async {
        let title = trimmedNew
        guard !title.isEmpty, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        let draft = TaskDraft(
            title: title,
            startTime: Date(),
            kind: .task,
            horizon: .day
        )
        do {
            _ = try await env.tasksRepository.create(draft)
            newTitle = ""
            await loadTasks()
        } catch {
            errorMessage = "Could not create: \(error.localizedDescription)"
        }
    }
}
