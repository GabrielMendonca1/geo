import GeoCore
import SwiftUI
import UIKit

struct TodayView: View {
    @StateObject private var viewModel = TodayViewModel()
    @State private var showCompleted = false
    @State private var showNewTask = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isEmpty, viewModel.isLoading, !viewModel.hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(SkyBackground())
                } else if viewModel.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if !viewModel.isAuthorized {
                        accessBanner
                    }
                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .background(.bar)
                    }
                }
            }
            .navigationTitle(viewModel.dayTitle)
            .settingsToolbar()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewTask = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewTask) {
                NewTaskSheet { draft in
                    viewModel.create(draft)
                }
            }
        }
        .task { await viewModel.reload() }
    }

    private var list: some View {
        List {
            taskSection("Overdue", tasks: viewModel.overdue, headerColor: .red)
            agendaSection
            taskSection("Upcoming", tasks: viewModel.upcoming, headerColor: .secondary)
            if !viewModel.completedToday.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showCompleted) {
                        ForEach(viewModel.completedToday) { task in
                            row(for: task, completed: true)
                                .listRowBackground(Color.cardSurface)
                                .swipeActions(edge: .leading) {
                                    Button {
                                        viewModel.reopen(task)
                                    } label: {
                                        Label("Reopen", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(.actionBlue)
                                }
                        }
                    } label: {
                        Text("Completed Today (\(viewModel.completedToday.count))")
                            .font(.subheadline.weight(.semibold))
                            .textCase(nil)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.cardSurface)
                }
            }
        }
        .listStyle(.insetGrouped)
        .skyScreen()
        .refreshable { await viewModel.reload() }
    }

    @ViewBuilder
    private var agendaSection: some View {
        if !viewModel.todayAgenda.isEmpty {
            Section {
                ForEach(viewModel.todayAgenda) { entry in
                    switch entry {
                    case .task(let task):
                        row(for: task)
                            .listRowBackground(Color.cardSurface)
                            .swipeActions(edge: .trailing) {
                                Button {
                                    viewModel.complete(task)
                                } label: {
                                    Label("Done", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                    case .event(let event):
                        eventRow(for: event)
                            .listRowBackground(Color.cardSurface)
                    }
                }
            } header: {
                Text("Today")
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func taskSection(_ title: String, tasks: [TaskItem], headerColor: Color) -> some View {
        if !tasks.isEmpty {
            Section {
                ForEach(tasks) { task in
                    row(for: task)
                        .listRowBackground(Color.cardSurface)
                        .swipeActions(edge: .trailing) {
                            Button {
                                viewModel.complete(task)
                            } label: {
                                Label("Done", systemImage: "checkmark")
                            }
                            .tint(.green)
                        }
                }
            } header: {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
                    .foregroundStyle(headerColor)
            }
        }
    }

    private func row(for task: TaskItem, completed: Bool = false) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy) {
                    if completed {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        viewModel.reopen(task)
                    } else {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        viewModel.complete(task)
                    }
                }
            } label: {
                Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(completed ? Color.actionBlue : .secondary)
                    .font(.title3)
                    .frame(width: 44, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(completed, color: .secondary)
                    .foregroundStyle(completed ? .secondary : .primary)
                Text(task.scheduleDisplayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if task.priority != .unset {
                Image(systemName: task.priority.icon)
                    .font(.caption)
                    .foregroundStyle(priorityColor(task.priority))
            }
            Image(systemName: task.kind.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func eventRow(for event: CalendarEventItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: TaskKind.event.icon)
                .foregroundStyle(.secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                if let calendarTitle = event.calendarTitle {
                    Text(calendarTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(eventTimeLabel(event))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func eventTimeLabel(_ event: CalendarEventItem) -> String {
        if event.isAllDay { return "All-day" }
        let t = MobileDateFormatters.shortTime
        if let end = event.end {
            return "\(t.string(from: event.start))–\(t.string(from: end))"
        }
        return t.string(from: event.start)
    }

    private func priorityColor(_ priority: TaskPriority) -> Color {
        switch priority {
        case .urgent: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .unset: return .gray
        }
    }

    private var emptyState: some View {
        GeometryReader { geo in
            ScrollView {
                AirStateCard(
                    icon: "calendar",
                    title: "Nothing today",
                    message: "No events or tasks scheduled for today."
                )
                .frame(minHeight: geo.size.height)
            }
            .refreshable { await viewModel.reload() }
        }
    }

    private var accessBanner: some View {
        HStack {
            Label("Calendar access needed", systemImage: "calendar.badge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Grant Access") {
                Task { await viewModel.requestAccess() }
            }
            .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct NewTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var due = Date()
    @State private var priority: TaskPriority = .unset
    let onCreate: (TaskDraft) -> Void

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                DatePicker("Due", selection: $due)
                Picker("Priority", selection: $priority) {
                    ForEach(TaskPriority.allCases) { priority in
                        Text(priority.displayName).tag(priority)
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onCreate(TaskDraft(
                            title: trimmedTitle,
                            priority: priority,
                            body: .task(due: due, estimatedMinutes: nil),
                            reminders: [.atTime()]
                        ))
                        dismiss()
                    }
                    .disabled(trimmedTitle.isEmpty)
                }
            }
        }
    }
}
