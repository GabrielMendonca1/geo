import GeoCore
import SwiftUI

struct TasksView: View {
    @StateObject private var viewModel = TasksViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if !viewModel.isAuthorized {
                    accessPrompt
                } else if viewModel.pending.isEmpty && viewModel.completed.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Tasks")
        }
        .task { await viewModel.reload() }
    }

    private var list: some View {
        List {
            if !viewModel.pending.isEmpty {
                Section("Pending") {
                    ForEach(viewModel.pending) { reminder in
                        row(for: reminder)
                    }
                }
            }
            if !viewModel.completed.isEmpty {
                Section("Completed") {
                    ForEach(viewModel.completed) { reminder in
                        row(for: reminder)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await viewModel.reload() }
    }

    private func row(for reminder: ReminderItem) -> some View {
        Button {
            viewModel.toggle(reminder)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reminder.isCompleted ? Color.accentColor : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(reminder.title)
                        .strikethrough(reminder.isCompleted, color: .secondary)
                        .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                    if let due = viewModel.dueLabel(for: reminder) {
                        Text(due)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: reminder.kind.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No reminders",
            systemImage: "checklist",
            description: Text("Reminders synced from your Mac will appear here.")
        )
    }

    private var accessPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Reminders access needed")
                .font(.headline)
            Button("Grant Access") {
                Task { await viewModel.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
