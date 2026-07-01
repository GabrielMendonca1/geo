import SwiftUI
import GeoCore

extension TaskPriority {
    var tintColor: Color? {
        switch self {
        case .urgent: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .unset: return nil
        }
    }
}

private enum BoardColumnKind: String, Identifiable {
    case overdue
    case today
    case later
    case goals
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .later: return "Later"
        case .goals: return "Goals"
        case .done: return "Done"
        }
    }

    var dotColor: Color {
        switch self {
        case .overdue: return Color(nsColor: Palette.agentDanger)
        case .today: return GeoStyle.Colors.geoBlueDark
        case .later: return Color(nsColor: .systemTeal)
        case .goals: return Color(nsColor: .systemPurple)
        case .done: return Color(nsColor: Palette.agentSuccess)
        }
    }

    var emptyHint: String? {
        switch self {
        case .today: return "Nothing for today"
        case .later: return "Nothing upcoming"
        default: return nil
        }
    }

    var acceptsDrops: Bool {
        switch self {
        case .today, .later, .done: return true
        case .overdue, .goals: return false
        }
    }

    var supportsInlineAdd: Bool {
        self == .today || self == .later
    }

    var inlineAddDayOffset: Int {
        self == .later ? 1 : 0
    }
}

struct TasksPane: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.navigationStore) private var navigationStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var viewModel = TasksViewModel()
    @StateObject private var agendaViewModel = DayAgendaViewModel()
    @State private var showingTaskForm = false
    @State private var editingTask: TaskItem?
    @State private var pendingPreFillBlockId: String?
    @State private var windowSize: CGSize = .zero
    @State private var quickTitle = ""
    @State private var dropTargetColumn: BoardColumnKind?
    @State private var addingInColumn: BoardColumnKind?
    @State private var columnDraftTitle = ""
    @FocusState private var columnAddFocused: Bool
    @FocusState private var quickAddFocused: Bool
    @State private var isSearchExpanded = false
    @FocusState private var isSearchFieldFocused: Bool

    private var responsiveLayout: ResponsiveLayout {
        ResponsiveLayout(windowSize: windowSize)
    }

    private var taskListFontSize: CGFloat {
        responsiveLayout.editorFontSize * 1.12
    }

    var body: some View {
        let _ = PerformanceTracker.shared.recordRender("TasksPane")
        Pane {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    filterBar
                    quickAddBar
                    dayAgenda

                    if viewModel.tasks.isEmpty {
                        emptyState
                    } else if viewModel.filteredTasks.isEmpty {
                        noResultsState
                    } else {
                        board
                    }
                }

                completionSuggestionStack
                    .padding(.trailing, GeoStyle.Spacing.editorPadding * responsiveLayout.scale)
                    .padding(.bottom, GeoStyle.Spacing.editorPadding * responsiveLayout.scale)
            }
        }
        .readSize { size in
            if windowSize != size { windowSize = size }
        }
        .sheet(isPresented: $showingTaskForm, onDismiss: { pendingPreFillBlockId = nil }) {
            TaskFormView(editingTask: nil, availableBlocks: viewModel.blockOptions, preFillBlockId: pendingPreFillBlockId)
        }
        .sheet(item: $editingTask) { task in
            TaskFormView(editingTask: task, availableBlocks: viewModel.blockOptions)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTaskCreateForm)) { notification in
            pendingPreFillBlockId = notification.userInfo?["preFillBlockId"] as? String
            editingTask = nil
            showingTaskForm = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTaskForm)) { notification in
            guard let taskId = notification.userInfo?["taskId"] as? String else { return }
            Task {
                guard let task = await viewModel.task(withID: taskId) else { return }
                await MainActor.run {
                    showingTaskForm = false
                    editingTask = task
                }
            }
        }
        .task {
            viewModel.bindIfNeeded(
                tasksRepository: appEnvironment.tasksRepository,
                blocksRepository: appEnvironment.blocksRepository
            )
        }
        .onChange(of: navigationStore.searchTexts[.tasks]) { _, newValue in
            viewModel.searchText = newValue ?? ""
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                newTaskChip
                searchControl
                filterChip("All", active: viewModel.filterKind == nil) {
                    viewModel.filterKind = nil
                }
                ForEach(TaskKind.allCases) { kind in
                    filterChip(kind.displayName, icon: kind.icon, active: viewModel.filterKind == kind) {
                        viewModel.filterKind = viewModel.filterKind == kind ? nil : kind
                    }
                }
                showCompletedChip
            }
            .padding(.horizontal, responsiveLayout.editorPaddingHorizontal)
            .padding(.vertical, 12)
        }
    }

    private var newTaskChip: some View {
        filterChip("New", icon: "plus", active: false) {
            showingTaskForm = true
        }
        .keyboardShortcut("n", modifiers: .command)
    }

    private var showCompletedChip: some View {
        filterChip(
            viewModel.showCompleted ? "Hide Completed" : "Show Completed",
            icon: "checkmark.circle",
            active: viewModel.showCompleted
        ) {
            viewModel.showCompleted.toggle()
        }
    }

    @ViewBuilder
    private var searchControl: some View {
        if isSearchExpanded {
            taskSearchField
        } else {
            taskSearchIconButton
        }
    }

    private var taskSearchIconButton: some View {
        Button {
            expandTaskSearch()
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundColor(.primary)
                .background(Capsule().fill(Color.clear))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .keyboardShortcut("f", modifiers: .command)
        .help("Search")
        .accessibilityLabel("Search")
    }

    private var taskSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            TextField("Search", text: Binding(
                get: { navigationStore.searchTexts[.tasks] ?? "" },
                set: { navigationStore.searchTexts[.tasks] = $0 }
            ))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
                .focused($isSearchFieldFocused)
                .onSubmit { isSearchFieldFocused = false }
            if !(navigationStore.searchTexts[.tasks] ?? "").isEmpty {
                Button {
                    navigationStore.searchTexts[.tasks] = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                collapseTaskSearch()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close search")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        .fixedSize()
    }

    private func expandTaskSearch() {
        isSearchExpanded = true
        DispatchQueue.main.async { isSearchFieldFocused = true }
    }

    private func collapseTaskSearch() {
        navigationStore.searchTexts[.tasks] = ""
        isSearchFieldFocused = false
        isSearchExpanded = false
    }

    @ViewBuilder
    private func filterChip(_ label: String, icon: String? = nil, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundColor(active ? .white : .primary)
            .background(
                Capsule()
                    .fill(active ? Color.accentColor : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        active ? Color.clear : Color.primary.opacity(0.18),
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var quickAddBar: some View {
        HStack(spacing: 8 * responsiveLayout.scale) {
            Image(systemName: "plus.circle")
                .font(.system(size: responsiveLayout.editorFontSize * 0.9, weight: .medium))
                .foregroundStyle(Palette.tertiaryForeground)

            TextField("Add task, event, or meeting...", text: $quickTitle)
                .textFieldStyle(.plain)
                .font(.system(size: responsiveLayout.editorFontSize * 0.92))
                .focused($quickAddFocused)
                .onSubmit { submitQuickAdd() }

            if !quickTitle.isEmpty {
                Button { submitQuickAdd() } label: {
                    Image(systemName: "return")
                        .font(.system(size: responsiveLayout.editorFontSize * 0.72, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 14 * responsiveLayout.scale)
        .padding(.vertical, 10 * responsiveLayout.scale)
        .background(
            RoundedRectangle(cornerRadius: 10 * responsiveLayout.scale)
                .fill(Palette.secondaryBackground.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10 * responsiveLayout.scale)
                .stroke(quickAddFocused ? Palette.accent.opacity(0.4) : Palette.border.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, responsiveLayout.editorPaddingHorizontal)
        .padding(.bottom, 8 * responsiveLayout.scale)
    }

    private var dayAgenda: some View {
        DayAgendaView(
            viewModel: agendaViewModel,
            tasks: viewModel.tasks,
            scale: responsiveLayout.scale,
            fontSize: responsiveLayout.editorFontSize,
            onEditTask: { id in
                if let task = viewModel.tasks.first(where: { $0.id == id }) {
                    editingTask = task
                }
            },
            onCompleteTask: { id in
                Task { await viewModel.completeTask(id: id) }
            }
        )
        .padding(.horizontal, responsiveLayout.editorPaddingHorizontal)
        .padding(.bottom, 8 * responsiveLayout.scale)
    }

    private func submitQuickAdd() {
        let trimmed = quickTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        quickTitle = ""
        let filterKind = viewModel.filterKind
        Task {
            do {
                let result = try await AITaskParser.parse(trimmed)
                var draft = result.draft
                if result.source == .local, draft.body.kind == .task, let filterKind {
                    draft.body = coerceBodyKind(draft.body, to: filterKind)
                }
                _ = try? await appEnvironment.tasksRepository.create(draft)
            } catch {
                let parsed = QuickAddParser.parse(trimmed)
                let draft = makeQuickAddDraft(from: parsed, rawInput: trimmed)
                _ = try? await appEnvironment.tasksRepository.create(draft)
            }
        }
    }

    private func makeQuickAddDraft(from parsed: ParsedQuickAdd, rawInput: String) -> TaskDraft {
        let useParsed = parsed.confidence != .low
        let resolvedTitle: String = {
            if useParsed {
                let trimmed = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? rawInput : trimmed
            }
            return rawInput
        }()

        let body: TaskBody
        if useParsed {
            if let filterKind = viewModel.filterKind, parsed.body.kind == .task {
                body = coerceBodyKind(parsed.body, to: filterKind)
            } else {
                body = parsed.body
            }
        } else {
            let endOfToday = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date()) ?? Date()
            let fallbackKind = viewModel.filterKind ?? .task
            body = coerceBodyKind(.task(due: endOfToday, estimatedMinutes: nil), to: fallbackKind)
        }

        return TaskDraft(title: resolvedTitle, body: body)
    }

    private func coerceBodyKind(_ body: TaskBody, to kind: TaskKind) -> TaskBody {
        if body.kind == kind { return body }
        let anchor = body.anchorDate
        switch kind {
        case .task:
            return .task(due: anchor, estimatedMinutes: nil)
        case .event:
            return .event(start: anchor, end: anchor.addingTimeInterval(3600), externalEKEventID: nil)
        case .habit:
            return .habit(rule: .daily, timeOfDay: anchor, occurrences: [])
        case .milestone:
            return .milestone(target: Calendar.current.startOfDay(for: anchor))
        }
    }

    @ViewBuilder
    private var completionSuggestionStack: some View {
        let suggestions = viewModel.visibleSuggestions
        if !suggestions.isEmpty {
            VStack(alignment: .trailing, spacing: 8 * responsiveLayout.scale) {
                ForEach(suggestions) { suggestion in
                    TaskCompletionSuggestionToast(
                        suggestion: suggestion,
                        scale: responsiveLayout.scale,
                        fontSize: responsiveLayout.editorFontSize,
                        onAccept: {
                            Task { await viewModel.acceptSuggestion(id: suggestion.id) }
                        },
                        onDismiss: {
                            viewModel.dismissSuggestion(id: suggestion.id)
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: suggestions.map(\.id))
        }
    }

    private var emptyState: some View {
        emptyPane(icon: "checklist", title: "No Tasks", message: "Type above or press + to create a task")
    }

    private var noResultsState: some View {
        emptyPane(icon: "magnifyingglass", title: "No Results", message: "No tasks match your filters")
    }

    private func emptyPane(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 16 * responsiveLayout.scale) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48 * responsiveLayout.scale))
                .foregroundStyle(Palette.tertiaryForeground)
            Text(title)
                .font(.system(size: responsiveLayout.editorFontSize * 1.1, weight: .semibold))
            Text(message)
                .font(.system(size: responsiveLayout.editorFontSize * 0.9))
                .foregroundStyle(Palette.tertiaryForeground)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var board: some View {
        let scale = responsiveLayout.scale
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14 * scale) {
                if !viewModel.overdueTasks.isEmpty {
                    boardColumn(.overdue, tasks: viewModel.overdueTasks)
                }
                boardColumn(.today, tasks: viewModel.todayTasks)
                boardColumn(.later, tasks: viewModel.upcomingTasks)
                if !viewModel.milestones.isEmpty {
                    boardColumn(.goals, tasks: viewModel.milestones)
                }
                if viewModel.showCompleted && !viewModel.completedTasks.isEmpty {
                    boardColumn(.done, tasks: viewModel.completedTasks)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: visibleColumnsSignature)
            .padding(.horizontal, responsiveLayout.editorPaddingHorizontal)
            .padding(.top, responsiveLayout.editorPaddingVertical * 0.5)
            .padding(.bottom, 14 * scale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleColumnsSignature: [Bool] {
        [
            viewModel.overdueTasks.isEmpty,
            viewModel.milestones.isEmpty,
            viewModel.showCompleted && !viewModel.completedTasks.isEmpty
        ]
    }

    @ViewBuilder
    private func boardColumn(_ column: BoardColumnKind, tasks: [TaskItem]) -> some View {
        let scale = responsiveLayout.scale
        let isDropTarget = dropTargetColumn == column
        let base = VStack(alignment: .leading, spacing: 0) {
            columnHeader(column, count: tasks.count)
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8 * scale) {
                    if tasks.isEmpty, let hint = column.emptyHint {
                        Text(hint)
                            .font(.system(size: responsiveLayout.editorFontSize * 0.82))
                            .foregroundStyle(Palette.tertiaryForeground.opacity(0.7))
                            .padding(.horizontal, 4 * scale)
                            .padding(.vertical, 8 * scale)
                    } else {
                        ForEach(tasks) { task in
                            taskCard(task)
                                .draggable(task.id)
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }
                    }
                    if column.supportsInlineAdd {
                        columnAddFooter(column)
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: tasks.map(\.id))
                .padding(10 * scale)
            }
        }
        .frame(width: 300 * scale)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16 * scale)
                .fill(Palette.secondaryBackground.opacity(isDropTarget ? 0.7 : 0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16 * scale)
                .strokeBorder(
                    isDropTarget ? GeoStyle.Colors.geoBlueDark.opacity(0.7) : Palette.border.opacity(0.3),
                    lineWidth: isDropTarget ? 1.5 : 1
                )
        )

        if column.acceptsDrops {
            base.dropDestination(for: String.self) { ids, _ in
                handleDrop(ids, on: column)
            } isTargeted: { targeted in
                dropTargetColumn = targeted ? column : (dropTargetColumn == column ? nil : dropTargetColumn)
            }
        } else {
            base
        }
    }

    @ViewBuilder
    private func columnHeader(_ column: BoardColumnKind, count: Int) -> some View {
        let scale = responsiveLayout.scale
        HStack(spacing: 8 * scale) {
            RoundedRectangle(cornerRadius: 3 * scale)
                .fill(column.dotColor)
                .frame(width: 10 * scale, height: 10 * scale)
            Text(column.title)
                .font(.system(size: responsiveLayout.editorFontSize * 0.92, weight: .semibold))
                .foregroundStyle(Palette.foreground)
            Text("\(count)")
                .font(.system(size: responsiveLayout.editorFontSize * 0.72, weight: .medium))
                .foregroundStyle(column == .overdue ? Color(nsColor: Palette.agentDanger) : Palette.tertiaryForeground)
                .padding(.horizontal, 7 * scale)
                .padding(.vertical, 2 * scale)
                .background(Capsule().fill(Palette.secondaryBackground.opacity(0.9)))
            Spacer(minLength: 0)
            columnMenu(column)
        }
        .padding(.horizontal, 14 * scale)
        .padding(.top, 12 * scale)
        .padding(.bottom, 4 * scale)
    }

    @ViewBuilder
    private func columnMenu(_ column: BoardColumnKind) -> some View {
        switch column {
        case .overdue:
            Menu {
                Button("Move all to Today") {
                    Task { await viewModel.moveOverdueToToday() }
                }
            } label: {
                columnMenuIcon
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        case .done:
            Menu {
                Button("Clear completed", role: .destructive) {
                    Task { await viewModel.clearCompleted() }
                }
            } label: {
                columnMenuIcon
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        default:
            EmptyView()
        }
    }

    private var columnMenuIcon: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: responsiveLayout.editorFontSize * 0.8, weight: .semibold))
            .foregroundStyle(Palette.tertiaryForeground)
            .frame(width: 22 * responsiveLayout.scale, height: 22 * responsiveLayout.scale)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func columnAddFooter(_ column: BoardColumnKind) -> some View {
        let scale = responsiveLayout.scale
        if addingInColumn == column {
            HStack(spacing: 6 * scale) {
                TextField("New task", text: $columnDraftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: responsiveLayout.editorFontSize * 0.88))
                    .focused($columnAddFocused)
                    .onSubmit { submitColumnAdd(column) }
                Button {
                    closeColumnAdd()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: responsiveLayout.editorFontSize * 0.62, weight: .semibold))
                        .foregroundStyle(Palette.tertiaryForeground)
                        .frame(width: 20 * scale, height: 20 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.horizontal, 11 * scale)
            .padding(.vertical, 9 * scale)
            .background(
                RoundedRectangle(cornerRadius: 10 * scale)
                    .fill(Palette.background.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10 * scale)
                    .strokeBorder(GeoStyle.Colors.geoBlueDark.opacity(0.5), lineWidth: 1)
            )
            .onExitCommand { closeColumnAdd() }
        } else {
            Button {
                addingInColumn = column
                columnDraftTitle = ""
                DispatchQueue.main.async { columnAddFocused = true }
            } label: {
                HStack(spacing: 6 * scale) {
                    Image(systemName: "plus")
                        .font(.system(size: responsiveLayout.editorFontSize * 0.7, weight: .semibold))
                    Text("Add card")
                        .font(.system(size: responsiveLayout.editorFontSize * 0.82, weight: .medium))
                }
                .foregroundStyle(Palette.tertiaryForeground)
                .padding(.horizontal, 8 * scale)
                .padding(.vertical, 7 * scale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
    }

    private func closeColumnAdd() {
        addingInColumn = nil
        columnDraftTitle = ""
        columnAddFocused = false
    }

    private func submitColumnAdd(_ column: BoardColumnKind) {
        let trimmed = columnDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            closeColumnAdd()
            return
        }
        columnDraftTitle = ""
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: column.inlineAddDayOffset, to: cal.startOfDay(for: Date())) ?? Date()
        let due = cal.date(bySettingHour: 23, minute: 59, second: 59, of: day) ?? day
        let draft = TaskDraft(title: trimmed, body: .task(due: due, estimatedMinutes: nil))
        Task { _ = try? await appEnvironment.tasksRepository.create(draft) }
    }

    private func handleDrop(_ ids: [String], on column: BoardColumnKind) -> Bool {
        guard !ids.isEmpty else { return false }
        Task {
            for id in ids {
                switch column {
                case .today:
                    await viewModel.reschedule(id: id, dayOffset: 0)
                case .later:
                    await viewModel.reschedule(id: id, dayOffset: 1)
                case .done:
                    await viewModel.completeTask(id: id)
                case .overdue, .goals:
                    break
                }
            }
        }
        return true
    }

    private func taskCard(_ task: TaskItem) -> some View {
        TaskCard(
            task: task,
            fontSize: taskListFontSize,
            layoutScale: responsiveLayout.scale,
            linkedBlockTitle: viewModel.linkedBlockTitle(for: task),
            hasLinkedBlock: viewModel.hasLinkedBlock(task),
            checkboxes: viewModel.checkboxes(for: task),
            onEdit: { editingTask = $0 },
            onComplete: { id in Task { await viewModel.completeTask(id: id) } },
            onMarkPending: { id in Task { await viewModel.markTaskPending(id: id) } },
            onDelete: { id in Task { await viewModel.deleteTask(id: id) } },
            onReschedule: { id, offset in Task { await viewModel.reschedule(id: id, dayOffset: offset) } },
            onToggleCheckbox: { taskId, blockId, line in
                Task { await viewModel.toggleCheckbox(in: blockId, lineNumber: line, taskId: taskId) }
            },
            onOpenBlock: { blockId in openWindow(id: "editor", value: blockId) }
        )
    }
}

private struct TaskCard: View {
    let task: TaskItem
    var fontSize: CGFloat = GeoStyle.Typography.editorFontSize
    var layoutScale: CGFloat = 1
    let linkedBlockTitle: String?
    var hasLinkedBlock: Bool = false
    var checkboxes: [BlockCheckbox] = []
    let onEdit: (TaskItem) -> Void
    let onComplete: (String) -> Void
    let onMarkPending: (String) -> Void
    let onDelete: (String) -> Void
    var onReschedule: ((String, Int) -> Void)? = nil
    var onToggleCheckbox: ((String, String, Int) -> Void)? = nil
    var onOpenBlock: ((String) -> Void)? = nil
    @State private var isHovering = false
    @State private var checklistExpanded = false

    private static let maxInlineCheckboxes = 5

    private var titleFontSize: CGFloat { fontSize * 0.95 }
    private var subtitleFontSize: CGFloat { fontSize * 0.76 }
    private var chipFontSize: CGFloat { fontSize * 0.7 }
    private var iconFontSize: CGFloat { fontSize * 0.74 }
    private var badgeSize: CGFloat { fontSize * 1.7 }

    private var isCompleted: Bool { task.status == .completed }

    private var showsLinkedBlockSection: Bool {
        hasLinkedBlock && linkedBlockTitle != nil
    }

    private var typeColor: Color {
        switch task.body {
        case .task: return GeoStyle.Colors.geoBlueDark
        case .event: return Color(nsColor: Palette.agentWarning)
        case .habit: return Color(nsColor: Palette.agentSuccess)
        case .milestone: return Color(nsColor: .systemPurple)
        }
    }

    private var checkboxesCompletedCount: Int { checkboxes.filter(\.checked).count }
    private var checkboxesTotalCount: Int { checkboxes.count }
    private var visibleCheckboxes: [BlockCheckbox] {
        Array(checkboxes.prefix(Self.maxInlineCheckboxes))
    }
    private var hiddenCheckboxCount: Int {
        max(0, checkboxes.count - Self.maxInlineCheckboxes)
    }
    private var checkboxProgress: Double {
        guard checkboxesTotalCount > 0 else { return 0 }
        return Double(checkboxesCompletedCount) / Double(checkboxesTotalCount)
    }

    private var showsPriorityFlag: Bool {
        task.priority == .urgent || task.priority == .high
    }

    private var canReschedule: Bool {
        task.isTask || task.isEvent
    }

    private var overdueDays: Int? {
        guard task.isOverdue else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: task.anchorDate),
            to: cal.startOfDay(for: Date())
        ).day
        return (days ?? 0) > 0 ? days : nil
    }

    private func whenText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return DateFormatters.shortTime.string(from: date)
        }
        return DateFormatters.mediumDate.string(from: date)
    }

    @ViewBuilder
    private func rowActionButton(icon: String, label: String = "", foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconFontSize, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 24 * layoutScale, height: 24 * layoutScale)
                .background(
                    RoundedRectangle(cornerRadius: 6 * layoutScale)
                        .fill(Palette.secondaryBackground.opacity(0.92))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .pointingHandCursor()
    }

    private var kindBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7 * layoutScale)
                .fill(typeColor.opacity(0.16))
            Image(systemName: task.kind.icon)
                .font(.system(size: fontSize * 0.78, weight: .semibold))
                .foregroundStyle(typeColor)
        }
        .frame(width: badgeSize, height: badgeSize)
    }

    @ViewBuilder
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5 * layoutScale) {
            if showsPriorityFlag, let tint = task.priority.tintColor {
                Image(systemName: task.priority.icon)
                    .font(.system(size: subtitleFontSize, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text(task.title)
                .font(.system(size: titleFontSize, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(isCompleted ? Palette.tertiaryForeground : Palette.foreground)
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        switch task.body {
        case .task(let due, _):
            HStack(spacing: 5 * layoutScale) {
                Text(whenText(due))
                if let days = overdueDays {
                    Text("·"); Text("\(days)d late")
                }
                if let dur = task.estimatedDuration {
                    Text("·"); Text(dur)
                }
                if !task.reminders.isEmpty {
                    Image(systemName: "bell.fill").font(.system(size: chipFontSize * 0.9))
                }
            }
            .font(.system(size: subtitleFontSize, weight: .medium))
            .foregroundStyle(task.isOverdue ? Color(nsColor: Palette.agentDanger) : Palette.tertiaryForeground)

        case .event(let start, let end, _):
            HStack(spacing: 5 * layoutScale) {
                Text("\(DateFormatters.shortTime.string(from: start)) – \(DateFormatters.shortTime.string(from: end))")
                if let days = overdueDays {
                    Text("·"); Text("\(days)d late")
                }
            }
            .font(.system(size: subtitleFontSize, weight: .medium))
            .foregroundStyle(task.isOverdue ? Color(nsColor: Palette.agentDanger) : Palette.tertiaryForeground)

        case .habit:
            HStack(spacing: 6 * layoutScale) {
                Text(task.recurrence.displayName)
                if task.habitCurrentStreak > 0 {
                    Text("·")
                    HStack(spacing: 3 * layoutScale) {
                        Image(systemName: "flame.fill")
                        Text("\(task.habitCurrentStreak)")
                    }
                    .foregroundStyle(Color(nsColor: Palette.agentWarning))
                }
                if task.isHabitCompletedToday {
                    Text("·")
                    HStack(spacing: 3 * layoutScale) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Done today")
                    }
                    .foregroundStyle(Color(nsColor: Palette.agentSuccess))
                }
            }
            .font(.system(size: subtitleFontSize, weight: .medium))
            .foregroundStyle(Palette.tertiaryForeground)

        case .milestone(let target):
            VStack(alignment: .leading, spacing: 5 * layoutScale) {
                if checkboxesTotalCount > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.secondaryBackground)
                            Capsule().fill(typeColor)
                                .frame(width: max(0, geo.size.width * checkboxProgress))
                        }
                    }
                    .frame(height: 4 * layoutScale)
                }
                HStack(spacing: 5 * layoutScale) {
                    if checkboxesTotalCount > 0 {
                        Text("\(checkboxesCompletedCount)/\(checkboxesTotalCount)")
                        Text("·")
                    }
                    if let days = task.daysUntilMilestone {
                        Text("\(days)d left")
                    } else {
                        Text(DateFormatters.mediumDate.string(from: target))
                    }
                }
                .font(.system(size: subtitleFontSize, weight: .medium))
                .foregroundStyle(Palette.tertiaryForeground)
            }
        }
    }

    @ViewBuilder
    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 5 * layoutScale) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { checklistExpanded.toggle() }
            } label: {
                HStack(spacing: 7 * layoutScale) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Palette.secondaryBackground.opacity(0.8))
                            Capsule()
                                .fill(typeColor)
                                .frame(width: max(0, geo.size.width * checkboxProgress))
                        }
                    }
                    .frame(height: 4 * layoutScale)

                    Text("\(checkboxesCompletedCount)/\(checkboxesTotalCount)")
                        .font(.system(size: chipFontSize, weight: .medium))
                        .foregroundStyle(Palette.tertiaryForeground)
                        .fixedSize(horizontal: true, vertical: false)

                    Image(systemName: checklistExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: chipFontSize * 0.85, weight: .semibold))
                        .foregroundStyle(Palette.tertiaryForeground)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if checklistExpanded {
                VStack(alignment: .leading, spacing: 4 * layoutScale) {
                    ForEach(visibleCheckboxes, id: \.lineNumber) { cb in
                        checkboxRow(cb)
                    }
                    if hiddenCheckboxCount > 0 {
                        Button {
                            if let blockId = task.linkedBlockId {
                                onOpenBlock?(blockId)
                            }
                        } label: {
                            Text("+\(hiddenCheckboxCount) more")
                                .font(.system(size: chipFontSize, weight: .medium))
                                .foregroundStyle(GeoStyle.Colors.geoBlueDark)
                                .padding(.vertical, 3 * layoutScale)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func checkboxRow(_ cb: BlockCheckbox) -> some View {
        Button {
            guard let blockId = task.linkedBlockId else { return }
            onToggleCheckbox?(task.id, blockId, cb.lineNumber)
        } label: {
            HStack(alignment: .top, spacing: 7 * layoutScale) {
                Image(systemName: cb.checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: subtitleFontSize, weight: .medium))
                    .foregroundStyle(cb.checked ? Color(nsColor: Palette.agentSuccess) : Palette.tertiaryForeground)
                Text(cb.text)
                    .font(.system(size: subtitleFontSize))
                    .lineLimit(2)
                    .foregroundStyle(cb.checked ? Palette.tertiaryForeground : Palette.foreground.opacity(0.9))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private var linkedBlockChip: some View {
        Button {
            if let blockId = task.linkedBlockId {
                onOpenBlock?(blockId)
            }
        } label: {
            HStack(spacing: 5 * layoutScale) {
                Image(systemName: "doc.text")
                    .font(.system(size: chipFontSize, weight: .medium))
                    .foregroundStyle(Palette.tertiaryForeground)
                Text(linkedBlockTitle ?? "")
                    .font(.system(size: chipFontSize, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(Palette.foreground.opacity(0.8))
            }
            .padding(.horizontal, 7 * layoutScale)
            .padding(.vertical, 3 * layoutScale)
            .background(
                RoundedRectangle(cornerRadius: 5 * layoutScale)
                    .fill(Palette.secondaryBackground.opacity(0.65))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private var hoverActions: some View {
        if isHovering {
            HStack(spacing: 4 * layoutScale) {
                if task.status == .pending {
                    if !task.isHabitCompletedToday {
                        rowActionButton(icon: "checkmark", label: "Complete task", foreground: Color(nsColor: Palette.agentSuccess)) {
                            onComplete(task.id)
                        }
                    }
                    rowActionButton(icon: "pencil", label: "Edit task", foreground: Palette.tertiaryForeground) {
                        onEdit(task)
                    }
                } else {
                    rowActionButton(icon: "arrow.uturn.backward", label: "Mark as pending", foreground: Palette.tertiaryForeground) {
                        onMarkPending(task.id)
                    }
                }
                rowActionButton(icon: "trash", label: "Delete task", foreground: Color(nsColor: Palette.agentDanger).opacity(0.8)) {
                    onDelete(task.id)
                }
            }
            .padding(6 * layoutScale)
            .transition(.opacity)
        }
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 9 * layoutScale) {
            kindBadge
            VStack(alignment: .leading, spacing: 4 * layoutScale) {
                titleRow
                metaLine
                if checkboxesTotalCount > 0 && !task.isMilestone {
                    checklistSection
                }
                if showsLinkedBlockSection {
                    linkedBlockChip
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11 * layoutScale)
        .padding(.vertical, 10 * layoutScale)
        .background(
            RoundedRectangle(cornerRadius: 10 * layoutScale)
                .fill(Palette.background.opacity(isHovering ? 0.75 : 0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10 * layoutScale)
                .strokeBorder(Palette.border.opacity(isHovering ? 0.7 : 0.45), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) { hoverActions }
        .contentShape(RoundedRectangle(cornerRadius: 10 * layoutScale))
        .shadow(
            color: Color.black.opacity(isHovering ? 0.18 : 0),
            radius: 8 * layoutScale,
            x: 0,
            y: 3 * layoutScale
        )
        .scaleEffect(isHovering ? 1.01 : 1)
    }

    var body: some View {
        cardContent
            .opacity(isCompleted ? 0.55 : 1)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .pointingHandCursor()
            .onTapGesture { onEdit(task) }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            }
            .contextMenu {
                if task.status == .pending {
                    Button("Edit") { onEdit(task) }
                    Button("Complete") { onComplete(task.id) }
                    if canReschedule {
                        Divider()
                        Button("Move to Today") { onReschedule?(task.id, 0) }
                        Button("Move to Tomorrow") { onReschedule?(task.id, 1) }
                    }
                    Divider()
                } else {
                    Button("Mark as Pending") { onMarkPending(task.id) }
                }
                Button("Delete", role: .destructive) { onDelete(task.id) }
            }
    }
}

private struct TaskCompletionSuggestionToast: View {
    let suggestion: PendingCompleteSuggestion
    let scale: CGFloat
    let fontSize: CGFloat
    let onAccept: () -> Void
    let onDismiss: () -> Void

    private var isMilestone: Bool { suggestion.kind == .milestone }

    @ViewBuilder
    private func toastButton(_ label: String, weight: Font.Weight, foreground: Color, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: fontSize * 0.82, weight: weight))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 6 * scale)
                .background(RoundedRectangle(cornerRadius: 6 * scale).fill(fill))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text(isMilestone ? "All beats done" : "All checkboxes done")
                .font(.system(size: fontSize * 0.78, weight: .semibold))
                .foregroundStyle(Palette.tertiaryForeground)
            Text(isMilestone ? "Ship \"\(suggestion.title)\"?" : "Mark \"\(suggestion.title)\" as done?")
                .font(.system(size: fontSize * 0.92, weight: .medium))
                .foregroundStyle(Palette.foreground)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8 * scale) {
                Spacer(minLength: 0)
                toastButton("Dismiss", weight: .medium, foreground: Palette.foreground, fill: Palette.secondaryBackground.opacity(0.6), action: onDismiss)
                toastButton(isMilestone ? "Ship it" : "Mark done", weight: .semibold, foreground: .white, fill: Palette.accent, action: onAccept)
            }
        }
        .padding(12 * scale)
        .frame(maxWidth: 320 * scale, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10 * scale).fill(Palette.background.opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 10 * scale).stroke(Palette.border.opacity(0.22), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.16), radius: 12 * scale, x: 0, y: 4 * scale)
    }
}

#Preview {
    TasksPane()
}
