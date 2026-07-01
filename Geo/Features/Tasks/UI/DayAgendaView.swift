import SwiftUI
import GeoCore

struct DayAgendaView: View {
    @ObservedObject var viewModel: DayAgendaViewModel
    let tasks: [TaskItem]
    let scale: CGFloat
    let fontSize: CGFloat
    let onEditTask: (String) -> Void
    let onCompleteTask: (String) -> Void

    @AppStorage("tasks.agenda.expanded") private var expanded = true
    @State private var creatingEvent = false
    @State private var editingEvent: AgendaRow?

    private var agendaKey: Int {
        var hasher = Hasher()
        hasher.combine(viewModel.selectedDay)
        hasher.combine(viewModel.changeToken)
        hasher.combine(viewModel.isAuthorized)
        hasher.combine(tasks)
        return hasher.finalize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            header
            if expanded {
                if !viewModel.isAuthorized {
                    accessPrompt
                }
                content
            }
        }
        .padding(.vertical, 10 * scale)
        .padding(.horizontal, 14 * scale)
        .background(
            RoundedRectangle(cornerRadius: 12 * scale)
                .fill(Palette.secondaryBackground.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12 * scale)
                .stroke(Palette.border.opacity(0.15), lineWidth: 1)
        )
        .sheet(isPresented: $creatingEvent) {
            EventEditorSheet(
                existing: nil,
                defaultDay: viewModel.selectedDay,
                onSave: { title, start, end, allDay in
                    viewModel.createEvent(title: title, start: start, end: end, isAllDay: allDay)
                },
                onDelete: nil
            )
        }
        .sheet(item: $editingEvent) { row in
            EventEditorSheet(
                existing: row,
                defaultDay: viewModel.selectedDay,
                onSave: { title, start, end, allDay in
                    guard let id = row.calendarEventId else { return }
                    viewModel.updateEvent(id: id, title: title, start: start, end: end, isAllDay: allDay)
                },
                onDelete: row.calendarEventId.map { id in { viewModel.deleteEvent(id: id) } }
            )
        }
        .onAppear { viewModel.updateRows(for: tasks) }
        .onChange(of: agendaKey) { _, _ in viewModel.updateRows(for: tasks) }
    }

    private var header: some View {
        HStack(spacing: 6 * scale) {
            navButton(icon: "chevron.left") { viewModel.goToPreviousDay() }
            Button {
                viewModel.goToToday()
            } label: {
                HStack(spacing: 5 * scale) {
                    Text(viewModel.dayTitle)
                        .font(.system(size: fontSize * 0.95, weight: .semibold))
                        .foregroundStyle(Palette.foreground)
                    if !viewModel.isToday {
                        Image(systemName: "arrow.uturn.left")
                            .font(.system(size: fontSize * 0.62, weight: .semibold))
                            .foregroundStyle(Palette.tertiaryForeground)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Jump to today")

            navButton(icon: "chevron.right") { viewModel.goToNextDay() }

            Spacer(minLength: 0)

            if expanded && viewModel.isAuthorized {
                Button {
                    creatingEvent = true
                } label: {
                    HStack(spacing: 4 * scale) {
                        Image(systemName: "plus")
                            .font(.system(size: fontSize * 0.7, weight: .semibold))
                        Text("Event")
                            .font(.system(size: fontSize * 0.78, weight: .medium))
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 9 * scale)
                    .padding(.vertical, 5 * scale)
                    .background(Capsule().fill(Palette.accent.opacity(0.12)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("New calendar event")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: fontSize * 0.72, weight: .semibold))
                    .foregroundStyle(Palette.tertiaryForeground)
                    .frame(width: 22 * scale, height: 22 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
    }

    private func navButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: fontSize * 0.72, weight: .semibold))
                .foregroundStyle(Palette.tertiaryForeground)
                .frame(width: 22 * scale, height: 22 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var accessPrompt: some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: fontSize * 0.85, weight: .medium))
                .foregroundStyle(Color(nsColor: Palette.agentWarning))
            Text("Grant Calendar access to see and add events.")
                .font(.system(size: fontSize * 0.8))
                .foregroundStyle(Palette.tertiaryForeground)
            Spacer(minLength: 0)
            Button {
                Task { await viewModel.requestAccess() }
            } label: {
                Text("Grant")
                    .font(.system(size: fontSize * 0.78, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10 * scale)
                    .padding(.vertical, 5 * scale)
                    .background(Capsule().fill(Palette.accent))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 8 * scale)
        .background(
            RoundedRectangle(cornerRadius: 8 * scale)
                .fill(Color(nsColor: Palette.agentWarning).opacity(0.08))
        )
    }

    @ViewBuilder
    private var content: some View {
        let items = viewModel.rows
        if items.isEmpty {
            Text("Nothing scheduled")
                .font(.system(size: fontSize * 0.82))
                .foregroundStyle(Palette.tertiaryForeground.opacity(0.8))
                .padding(.vertical, 6 * scale)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8 * scale) {
                    ForEach(items) { row in
                        agendaCard(row)
                    }
                }
                .padding(.vertical, 2 * scale)
            }
        }
    }

    private func agendaCard(_ row: AgendaRow) -> some View {
        HStack(spacing: 8 * scale) {
            leadingControl(row)
            Button {
                open(row)
            } label: {
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(row.timeLabel)
                        .font(.system(size: fontSize * 0.68, weight: .semibold))
                        .foregroundStyle(color(for: row))
                    Text(row.title)
                        .font(.system(size: fontSize * 0.82, weight: .medium))
                        .lineLimit(1)
                        .strikethrough(row.isCompleted, color: Palette.tertiaryForeground)
                        .foregroundStyle(row.isCompleted ? Palette.tertiaryForeground : Palette.foreground)
                    if let cal = row.calendarTitle {
                        Text(cal)
                            .font(.system(size: fontSize * 0.62))
                            .lineLimit(1)
                            .foregroundStyle(Palette.tertiaryForeground.opacity(0.8))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, 9 * scale)
        .padding(.vertical, 7 * scale)
        .frame(minWidth: 130 * scale, idealWidth: 160 * scale, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9 * scale)
                .fill(Palette.background.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9 * scale)
                .strokeBorder(color(for: row).opacity(0.35), lineWidth: 1)
        )
        .opacity(row.isCompleted ? 0.6 : 1)
    }

    @ViewBuilder
    private func leadingControl(_ row: AgendaRow) -> some View {
        if let taskId = row.completableTaskId {
            Button {
                if !row.isCompleted { onCompleteTask(taskId) }
            } label: {
                Image(systemName: row.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: fontSize * 0.95, weight: .medium))
                    .foregroundStyle(row.isCompleted ? Color(nsColor: Palette.agentSuccess) : color(for: row))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(row.isCompleted)
        } else {
            Image(systemName: row.kind.icon)
                .font(.system(size: fontSize * 0.9, weight: .medium))
                .foregroundStyle(color(for: row))
        }
    }

    private func color(for row: AgendaRow) -> Color {
        switch row.kind {
        case .event: return Color(nsColor: Palette.agentWarning)
        case .task: return GeoStyle.Colors.geoBlueDark
        case .habit: return Color(nsColor: Palette.agentSuccess)
        case .milestone: return Color(nsColor: .systemPurple)
        }
    }

    private func open(_ row: AgendaRow) {
        if row.calendarEventId != nil {
            editingEvent = row
        } else if let taskId = row.completableTaskId {
            onEditTask(taskId)
        }
    }
}

private struct EventEditorSheet: View {
    let existing: AgendaRow?
    let defaultDay: Date
    let onSave: (String, Date, Date, Bool) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var isAllDay: Bool

    init(
        existing: AgendaRow?,
        defaultDay: Date,
        onSave: @escaping (String, Date, Date, Bool) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.existing = existing
        self.defaultDay = defaultDay
        self.onSave = onSave
        self.onDelete = onDelete

        if let existing {
            _title = State(initialValue: existing.title)
            _start = State(initialValue: existing.start)
            _end = State(initialValue: existing.end ?? existing.start.addingTimeInterval(3600))
            _isAllDay = State(initialValue: existing.isAllDay)
        } else {
            let cal = Calendar.current
            let base: Date
            if cal.isDateInToday(defaultDay) {
                let next = cal.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
                base = cal.date(bySettingHour: cal.component(.hour, from: next), minute: 0, second: 0, of: next) ?? next
            } else {
                base = cal.date(bySettingHour: 9, minute: 0, second: 0, of: defaultDay) ?? defaultDay
            }
            _title = State(initialValue: "")
            _start = State(initialValue: base)
            _end = State(initialValue: base.addingTimeInterval(3600))
            _isAllDay = State(initialValue: false)
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New Event" : "Edit Event")
                .font(.title3.weight(.semibold))

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            Toggle("All-day", isOn: $isAllDay)

            DatePicker(
                "Starts",
                selection: $start,
                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
            )

            if !isAllDay {
                DatePicker(
                    "Ends",
                    selection: $end,
                    in: start...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard !trimmedTitle.isEmpty else { return }
                    let resolvedEnd = isAllDay ? start : max(end, start)
                    onSave(trimmedTitle, start, resolvedEnd, isAllDay)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
