import GeoCore
import SwiftUI

struct TodayView: View {
    @StateObject private var viewModel = TodayViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if !viewModel.isAuthorized {
                    accessPrompt
                } else if viewModel.rows.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(viewModel.dayTitle)
        }
        .task { await viewModel.reload() }
    }

    private var list: some View {
        List(viewModel.rows) { row in
            Button {
                viewModel.toggle(row)
            } label: {
                TodayRowView(row: row)
            }
            .buttonStyle(.plain)
            .disabled(row.reminderID == nil)
        }
        .listStyle(.plain)
        .refreshable { await viewModel.reload() }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing today",
            systemImage: "calendar",
            description: Text("No events or reminders scheduled for today.")
        )
    }

    private var accessPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Calendar & Reminders access needed")
                .font(.headline)
            Button("Grant Access") {
                Task { await viewModel.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct TodayRowView: View {
    let row: TodayRow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.reminderID != nil
                  ? (row.isCompleted ? "checkmark.circle.fill" : "circle")
                  : row.kind.icon)
                .foregroundStyle(row.isCompleted ? Color.accentColor : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .strikethrough(row.isCompleted, color: .secondary)
                    .foregroundStyle(row.isCompleted ? .secondary : .primary)
                if let calendarTitle = row.calendarTitle {
                    Text(calendarTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(row.timeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
