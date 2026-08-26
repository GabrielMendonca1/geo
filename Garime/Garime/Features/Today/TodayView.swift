import GeoCore
import SwiftUI
import UIKit

private enum TodaySheet: String, Identifiable {
    case newTask
    case settings

    var id: String { rawValue }
}

struct TodayView: View {
    @StateObject private var viewModel = TodayViewModel()
    @State private var showCompleted = false
    @State private var activeSheet: TodaySheet? = TodayView.initialSheet()
    @State private var calendarMode: CalendarMode = TodayView.initialCalendarMode()

    private static func initialCalendarMode() -> CalendarMode {
        guard let index = CommandLine.arguments.firstIndex(of: "-geoCalendar"),
              index + 1 < CommandLine.arguments.count,
              CommandLine.arguments[index + 1] == "month"
        else { return .week }
        return .month
    }

    private static func initialSheet() -> TodaySheet? {
        CommandLine.arguments.contains("-geoNewTask") ? .newTask : nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isEmpty, viewModel.isLoading, !viewModel.hasLoaded {
                    ProgressView()
                        .tint(.slateText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.slateCanvas)
                } else {
                    list
                }
            }
            .safeAreaInset(edge: .top) { chrome }
            .navigationBarHidden(true)
            .tint(Color.slateText)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .newTask:
                    NewTaskSheet { draft in
                        viewModel.create(draft)
                    }
                case .settings:
                    SettingsView()
                }
            }
        }
        .tint(Color.slateText)
        .task { await viewModel.reload() }
    }

    private var chrome: some View {
        VStack(spacing: 10) {
            GlassChrome {
                HStack(spacing: 8) {
                    Button {
                        toggleCalendarMode()
                    } label: {
                        HStack(spacing: 8) {
                            Text(viewModel.dayTitle)
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.primary)

                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(calendarMode == .month ? 180 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    chromeButton("plus") { activeSheet = .newTask }
                    chromeButton("gearshape") { activeSheet = .settings }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
            }

            calendarPanel
                .glassSurface(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 12)

            if !viewModel.isAuthorized {
                accessBanner
            }
            if let offline = viewModel.offlineMessage {
                banner(offline, icon: "wifi.slash")
            }
            if let error = viewModel.errorMessage {
                banner(error, icon: "exclamationmark.triangle")
            }
            if let calendarError = viewModel.calendarSyncError {
                banner(calendarError, icon: "calendar.badge.exclamationmark")
            }
        }
        .padding(.bottom, 10)
    }

    private func chromeButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSurface(shape: Circle(), interactive: true)
    }

    private func banner(_ message: String, icon: String) -> some View {
        Label(message, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }

    private var list: some View {
        List {
            if viewModel.isEmpty, viewModel.hasLoaded {
                Section {
                    VStack(spacing: 10) {
                        Text("nada aqui")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color.slateText)
                        Text("sem tarefas ou eventos")
                            .font(.caption)
                            .foregroundStyle(Color.slateTextDim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.slateCanvas)
                    .listRowSeparator(.hidden)
                    .transition(rowTransition)
                }
            }

            if !viewModel.overdue.isEmpty {
                Section {
                    ForEach(viewModel.overdue) { task in
                        taskCard(task, completed: false)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.slateCanvas)
                            .listRowSeparator(.hidden)
                            .transition(rowTransition)
                            .swipeActions(edge: .trailing) {
                                completeButton(for: task)
                                deleteButton(for: task)
                            }
                    }
                } header: {
                    Text("atrasadas")
                        .font(.caption)
                        .foregroundStyle(Color.slateTextFaint)
                        .textCase(nil)
                }
            }

            if !viewModel.todayAgenda.isEmpty {
                Section {
                    ForEach(viewModel.todayAgenda) { entry in
                        switch entry {
                        case .task(let task):
                            taskCard(task, completed: false)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowBackground(Color.slateCanvas)
                                .listRowSeparator(.hidden)
                                .transition(rowTransition)
                                .swipeActions(edge: .trailing) {
                                    completeButton(for: task)
                                    deleteButton(for: task)
                                }
                        case .event(let event):
                            eventCard(event)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowBackground(Color.slateCanvas)
                                .listRowSeparator(.hidden)
                                .transition(rowTransition)
                        }
                    }
                } header: {
                    Text(headerForSelectedDate())
                        .font(.caption)
                        .foregroundStyle(Color.slateTextFaint)
                        .textCase(nil)
                }
            }

            if !viewModel.completedToday.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showCompleted) {
                        ForEach(viewModel.completedToday) { task in
                            taskCard(task, completed: true)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowBackground(Color.slateCanvas)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .leading) {
                                    Button {
                                        viewModel.reopen(task)
                                    } label: {
                                        Label("Reopen", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(.slateElevated)
                                }
                                .swipeActions(edge: .trailing) {
                                    deleteButton(for: task)
                                }
                        }
                    } label: {
                        Text("concluídas (\(viewModel.completedToday.count))")
                            .font(.caption)
                            .foregroundStyle(Color.slateTextFaint)
                            .textCase(nil)
                    }
                    .tint(Color.slateText)
                    .listRowBackground(Color.slateCanvas)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.slateCanvas)
        .refreshable { await viewModel.reload() }
        .dockScrollTracking()
    }

    private var rowTransition: AnyTransition {
        .opacity.combined(with: .offset(y: 8))
    }

    @ViewBuilder
    private var calendarPanel: some View {
        if calendarMode == .month {
            MonthGridView(
                selectedDate: $viewModel.selectedDate,
                displayedMonth: viewModel.displayedMonth,
                hasItemsByDate: viewModel.hasItemsByDate,
                onShiftMonth: { months in
                    withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                        viewModel.shiftDisplayedMonth(by: months)
                    }
                },
                onSelect: { date in
                    withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                        viewModel.selectedDate = date
                        viewModel.syncDisplayedMonth(to: date)
                        calendarMode = .week
                    }
                }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        } else {
            WeekStripView(selectedDate: $viewModel.selectedDate, hasItemsByDate: viewModel.hasItemsByDate)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
    }

    private func toggleCalendarMode() {
        withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
            if calendarMode == .week {
                viewModel.syncDisplayedMonth(to: viewModel.selectedDate)
                calendarMode = .month
            } else {
                calendarMode = .week
            }
        }
    }

    private func taskCard(_ task: TaskItem, completed: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
                if completed {
                    ZStack {
                        Circle()
                            .fill(Color.slateText.opacity(0.38))
                            .frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.slateCanvas)
                    }
                } else {
                    Circle()
                        .stroke(Color.slateText.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                }
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(metadataLabel(for: task))
                    .font(.caption)
                    .foregroundStyle(Color.slateTextDim)

                Text(task.title)
                    .font(.body)
                    .foregroundStyle(completed ? Color.slateTextFaint : Color.slateText)
                    .lineLimit(2)
                    .lineSpacing(2)

                if !task.tagIds.isEmpty {
                    chipsView(for: task.tagIds)
                }
            }

            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private func eventCard(_ event: CalendarEventItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 18))
                .foregroundStyle(Color.slateTextDim)
                .frame(width: 22, height: 22, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(eventMetadataLabel(for: event))
                    .font(.caption)
                    .foregroundStyle(Color.slateTextDim)

                Text(event.title)
                    .font(.body)
                    .foregroundStyle(Color.slateText)
                    .lineLimit(2)
                    .lineSpacing(2)

                if let calendarTitle = event.calendarTitle {
                    Text(calendarTitle)
                        .font(.caption2)
                        .foregroundStyle(Color.slateTextFaint)
                }
            }

            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private func chipsView(for tagIds: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(tagIds.prefix(2)), id: \.self) { tagId in
                Text(String(tagId.prefix(3)))
                    .font(.caption2)
                    .foregroundStyle(Color.slateText.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(
                        Capsule()
                            .stroke(Color.slateStroke, lineWidth: 1)
                    )
            }
            if tagIds.count > 2 {
                Text("+\(tagIds.count - 2)")
                    .font(.caption2)
                    .foregroundStyle(Color.slateText.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(
                        Capsule()
                            .stroke(Color.slateStroke, lineWidth: 1)
                    )
            }
            Spacer()
        }
    }

    private func completeButton(for task: TaskItem) -> some View {
        Button {
            viewModel.complete(task)
        } label: {
            Label("Done", systemImage: "checkmark")
        }
        .tint(.green)
    }

    private func deleteButton(for task: TaskItem) -> some View {
        Button(role: .destructive) {
            viewModel.delete(task)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func metadataLabel(for task: TaskItem) -> String {
        let timeStr = MobileDateFormatters.shortTime.string(from: task.anchorDate)
        let typeStr: String
        switch task.body {
        case .task: typeStr = "tarefa"
        case .habit: typeStr = "hábito"
        case .event: typeStr = "evento"
        case .milestone: typeStr = "marco"
        }
        return "\(timeStr) · \(typeStr)"
    }

    private func eventMetadataLabel(for event: CalendarEventItem) -> String {
        if event.isAllDay { return "dia inteiro" }
        let formatter = MobileDateFormatters.shortTime
        if let end = event.end {
            return "\(formatter.string(from: event.start))–\(formatter.string(from: end))"
        }
        return formatter.string(from: event.start)
    }

    private func headerForSelectedDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        let cal = Calendar.current
        let isToday = cal.isDateInToday(viewModel.selectedDate)
        if isToday {
            return "hoje"
        }
        formatter.dateFormat = "EEEE, d 'de' MMMM"
        return formatter.string(from: viewModel.selectedDate).lowercased()
    }

    private var accessBanner: some View {
        HStack {
            Label("acesso ao calendário necessário", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("permitir") {
                Task { await viewModel.requestAccess() }
            }
            .font(.caption)
            .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}
