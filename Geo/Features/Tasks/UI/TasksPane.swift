import SwiftUI

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

struct TasksPane: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.navigationStore) private var navigationStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var viewModel = TasksViewModel()
    @State private var showingTaskForm = false
    @State private var editingTask: TaskItem?
    @State private var pendingPreFillBlockId: String?
    @State private var windowSize: CGSize = .zero
    @State private var quickTitle = ""
    @State private var goalsExpanded = false
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

                    if viewModel.tasks.isEmpty {
                        emptyState
                    } else if viewModel.filteredTasks.isEmpty {
                        noResultsState
                    } else {
                        taskList
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
                }
                .buttonStyle(.plain)
            }
            Button {
                collapseTaskSearch()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
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
            return .event(start: anchor, end: anchor.addingTimeInterval(3600))
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

    private var taskList: some View {
        let scale = responsiveLayout.scale
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18 * scale) {
                if !viewModel.overdueTasks.isEmpty {
                    taskSection("Overdue", viewModel.overdueTasks, tint: .red)
                }
                taskSection("Today", viewModel.todayTasks, tint: nil, emptyHint: "Nothing for today")
                if !viewModel.upcomingTasks.isEmpty {
                    taskSection("Later", viewModel.upcomingTasks, tint: nil)
                }
                if !viewModel.milestones.isEmpty {
                    collapsibleSection("Goals", icon: "flag.fill", viewModel.milestones, isExpanded: goalsExpanded) {
                        goalsExpanded.toggle()
                    }
                }
                if !viewModel.completedTasks.isEmpty {
                    collapsibleSection("Completed", icon: "checkmark.circle", viewModel.completedTasks, isExpanded: viewModel.showCompleted) {
                        viewModel.showCompleted.toggle()
                    }
                }
            }
            .frame(maxWidth: 760 * scale)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, responsiveLayout.editorPaddingHorizontal)
            .padding(.top, responsiveLayout.editorPaddingVertical * 0.5)
            .padding(.bottom, responsiveLayout.editorPaddingHorizontal + 56 * scale)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int, tint: Color?, leading: AnyView? = nil) -> some View {
        let scale = responsiveLayout.scale
        HStack(spacing: 6 * scale) {
            if let leading { leading }
            Text(title.uppercased())
                .font(.system(size: responsiveLayout.editorFontSize * 0.76, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(tint ?? Palette.tertiaryForeground)
            Text("\(count)")
                .font(.system(size: responsiveLayout.editorFontSize * 0.72, weight: .medium))
                .foregroundStyle(Palette.tertiaryForeground)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func taskSection(_ title: String, _ tasks: [TaskItem], tint: Color?, emptyHint: String? = nil) -> some View {
        let scale = responsiveLayout.scale
        VStack(alignment: .leading, spacing: 8 * scale) {
            sectionHeader(title, count: tasks.count, tint: tint)
            if tasks.isEmpty {
                if let emptyHint {
                    Text(emptyHint)
                        .font(.system(size: responsiveLayout.editorFontSize * 0.82))
                        .foregroundStyle(Palette.tertiaryForeground.opacity(0.7))
                }
            } else {
                ForEach(tasks) { task in
                    taskCard(task)
                }
            }
        }
    }

    @ViewBuilder
    private func collapsibleSection(_ title: String, icon: String, _ tasks: [TaskItem], isExpanded: Bool, toggle: @escaping () -> Void) -> some View {
        let scale = responsiveLayout.scale
        VStack(alignment: .leading, spacing: 8 * scale) {
            Button(action: toggle) {
                sectionHeader(
                    title,
                    count: tasks.count,
                    tint: nil,
                    leading: AnyView(
                        HStack(spacing: 6 * scale) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: responsiveLayout.editorFontSize * 0.7, weight: .semibold))
                                .foregroundStyle(Palette.tertiaryForeground)
                            Image(systemName: icon)
                                .font(.system(size: responsiveLayout.editorFontSize * 0.72))
                                .foregroundStyle(Palette.tertiaryForeground)
                        }
                    )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            if isExpanded {
                ForEach(tasks) { task in
                    taskCard(task)
                }
            }
        }
    }

    private func taskCard(_ task: TaskItem) -> some View {
        TaskCard(
            task: task,
            fontSize: taskListFontSize,
            layoutScale: responsiveLayout.scale,
            linkedBlockTitle: viewModel.linkedBlockTitle(for: task),
            linkedBlockCount: task.linkedBlockId.map { viewModel.linkedBlockCount(for: $0) } ?? 0,
            hasLinkedBlock: viewModel.hasLinkedBlock(task),
            checkboxes: viewModel.checkboxes(for: task),
            onEdit: { editingTask = $0 },
            onComplete: { id in Task { await viewModel.completeTask(id: id) } },
            onMarkPending: { id in Task { await viewModel.markTaskPending(id: id) } },
            onDelete: { id in Task { await viewModel.deleteTask(id: id) } },
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
    let linkedBlockCount: Int
    var hasLinkedBlock: Bool = false
    var checkboxes: [BlockCheckbox] = []
    let onEdit: (TaskItem) -> Void
    let onComplete: (String) -> Void
    let onMarkPending: (String) -> Void
    let onDelete: (String) -> Void
    var onToggleCheckbox: ((String, String, Int) -> Void)? = nil
    var onOpenBlock: ((String) -> Void)? = nil
    @State private var isHovering = false
    @State private var showCompleteAnimation = false

    private static let maxInlineCheckboxes = 5

    private var titleFontSize: CGFloat { fontSize * 1.08 }
    private var subtitleFontSize: CGFloat { fontSize * 0.8 }
    private var chipFontSize: CGFloat { fontSize * 0.72 }
    private var iconFontSize: CGFloat { fontSize * 0.78 }
    private var checkboxSize: CGFloat { fontSize * 1.24 }
    private var checkboxTapTargetSize: CGFloat { checkboxSize + (8 * layoutScale) }

    private var completionIndicatorScale: CGFloat {
        task.status == .completed ? 1 : (showCompleteAnimation ? 1 : 0)
    }

    private var detailText: String { "\(dateText) · \(timeText)" }

    private var reminderCount: Int { task.reminders.count }

    private var showsLinkedBlockSection: Bool {
        hasLinkedBlock && linkedBlockTitle != nil
    }

    private var hasMetaRow: Bool {
        task.recurrence.isRepeating
            || reminderCount > 0
            || (linkedBlockTitle != nil && !showsLinkedBlockSection)
            || task.isOverdue
            || task.estimatedDuration != nil
            || (task.isHabit && task.habitCurrentStreak > 0)
            || task.daysUntilMilestone != nil
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

    private var notesPreview: String {
        task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var timeFormatter: DateFormatter { DateFormatters.shortTime }

    private static var mediumDateFormatter: DateFormatter { DateFormatters.mediumDate }

    private var timeText: String {
        if let endTime = task.endTime {
            return "\(Self.timeFormatter.string(from: task.startTime)) - \(Self.timeFormatter.string(from: endTime))"
        }
        return Self.timeFormatter.string(from: task.startTime)
    }

    private static func friendlyDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return mediumDateFormatter.string(from: date)
    }

    private var dateText: String {
        let start = Self.friendlyDate(task.startTime)
        guard let endTime = task.endTime,
              !Calendar.current.isDate(task.startTime, inSameDayAs: endTime) else { return start }
        return "\(start) - \(Self.friendlyDate(endTime))"
    }

    private var linkedBlockChipText: String? {
        guard let linkedBlockTitle else { return nil }
        guard linkedBlockCount > 1 else { return linkedBlockTitle }
        return "\(linkedBlockTitle) (\(linkedBlockCount))"
    }

    private func toggleCompletionFromCheckbox() {
        if task.status == .completed {
            showCompleteAnimation = false
            onMarkPending(task.id)
            return
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
            showCompleteAnimation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            onComplete(task.id)
            showCompleteAnimation = false
        }
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
                        .fill(Palette.secondaryBackground.opacity(0.82))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func metaChip(_ text: String, icon: String, foreground: Color? = nil, background: Color? = nil) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: chipFontSize, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(foreground ?? Palette.tertiaryForeground)
            .padding(.horizontal, 7 * layoutScale)
            .padding(.vertical, 3 * layoutScale)
            .background(Capsule().fill(background ?? Palette.secondaryBackground.opacity(0.72)))
    }

    @ViewBuilder
    private var linkedBlockSection: some View {
        VStack(alignment: .leading, spacing: 6 * layoutScale) {
            linkedBlockChip

            if checkboxesTotalCount > 0 {
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
                                .foregroundStyle(Palette.accent)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }

                    progressRow
                }
                .padding(.top, 2 * layoutScale)
            }
        }
        .padding(.top, 2 * layoutScale)
    }

    @ViewBuilder
    private var linkedBlockChip: some View {
        Button {
            if let blockId = task.linkedBlockId {
                onOpenBlock?(blockId)
            }
        } label: {
            HStack(spacing: 6 * layoutScale) {
                Image(systemName: "doc.text")
                    .font(.system(size: chipFontSize, weight: .medium))
                    .foregroundStyle(Palette.tertiaryForeground)
                Text(linkedBlockTitle ?? "")
                    .font(.system(size: chipFontSize, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(Palette.foreground.opacity(0.85))
                Image(systemName: "chevron.right")
                    .font(.system(size: chipFontSize * 0.85, weight: .semibold))
                    .foregroundStyle(Palette.tertiaryForeground)
            }
            .padding(.horizontal, 8 * layoutScale)
            .padding(.vertical, 4 * layoutScale)
            .background(
                RoundedRectangle(cornerRadius: 6 * layoutScale)
                    .fill(Palette.secondaryBackground.opacity(0.55))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func checkboxRow(_ cb: BlockCheckbox) -> some View {
        Button {
            guard let blockId = task.linkedBlockId else { return }
            onToggleCheckbox?(task.id, blockId, cb.lineNumber)
        } label: {
            HStack(alignment: .top, spacing: 8 * layoutScale) {
                Image(systemName: cb.checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: subtitleFontSize * 1.05, weight: .medium))
                    .foregroundStyle(cb.checked ? Color(nsColor: Palette.agentSuccess) : Palette.tertiaryForeground)
                Text(cb.text)
                    .font(.system(size: subtitleFontSize))
                    .lineLimit(2)
                    .strikethrough(cb.checked)
                    .foregroundStyle(cb.checked ? Palette.tertiaryForeground : Palette.foreground.opacity(0.9))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private var progressRow: some View {
        HStack(spacing: 8 * layoutScale) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Palette.secondaryBackground.opacity(0.6))
                    Capsule()
                        .fill(Palette.accent)
                        .frame(width: max(0, geo.size.width * checkboxProgress))
                }
            }
            .frame(height: 5 * layoutScale)

            Text("\(checkboxesCompletedCount)/\(checkboxesTotalCount) done")
                .font(.system(size: chipFontSize, weight: .regular))
                .foregroundStyle(Palette.tertiaryForeground)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.top, 2 * layoutScale)
    }

    var body: some View {
        HStack(spacing: 0) {
            if task.priority != .unset {
                RoundedRectangle(cornerRadius: 2)
                    .fill(task.priority.tintColor ?? Palette.tertiaryForeground)
                    .frame(width: 3 * layoutScale)
                    .padding(.vertical, 6 * layoutScale)
            }

            VStack(alignment: .leading, spacing: 8 * layoutScale) {
                HStack(alignment: .top, spacing: 8 * layoutScale) {
                    Button(action: toggleCompletionFromCheckbox) {
                        let strokeColor: Color = task.status == .completed ? Color(nsColor: Palette.agentSuccess) : Palette.accent
                        ZStack {
                            Circle()
                                .stroke(strokeColor, lineWidth: 1.4 * layoutScale)
                                .frame(width: checkboxSize, height: checkboxSize)
                            Circle()
                                .fill(Color(nsColor: Palette.agentSuccess))
                                .frame(width: checkboxSize, height: checkboxSize)
                                .scaleEffect(completionIndicatorScale)
                                .opacity(Double(completionIndicatorScale))
                            Image(systemName: "checkmark")
                                .font(.system(size: fontSize * 0.56, weight: .bold))
                                .foregroundStyle(.white)
                                .scaleEffect(completionIndicatorScale)
                                .opacity(Double(completionIndicatorScale))
                        }
                        .frame(width: checkboxTapTargetSize, height: checkboxTapTargetSize)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()

                    HStack(spacing: 5 * layoutScale) {
                        if task.kind != .task {
                            Image(systemName: task.kind.icon)
                                .font(.system(size: titleFontSize * 0.82, weight: .medium))
                                .foregroundStyle(Palette.accent)
                        }
                        let titleColor: Color = task.status == .completed ? Palette.tertiaryForeground : Palette.foreground
                        Text(task.title)
                            .font(.system(size: titleFontSize, weight: .bold))
                            .lineLimit(2)
                            .strikethrough(task.status == .completed)
                            .foregroundStyle(titleColor)
                    }

                    Spacer(minLength: 0)

                    if isHovering && task.status == .pending {
                        HStack(spacing: 6 * layoutScale) {
                            rowActionButton(icon: "pencil", label: "Edit task", foreground: Palette.tertiaryForeground) {
                                onEdit(task)
                            }
                            rowActionButton(icon: "trash", label: "Delete task", foreground: Color(nsColor: Palette.agentDanger).opacity(0.8)) {
                                onDelete(task.id)
                            }
                        }
                        .transition(.opacity)
                    }
                }

                Label(detailText, systemImage: task.isEvent ? "calendar.badge.clock" : "calendar")
                    .font(.system(size: subtitleFontSize))
                    .lineLimit(1)
                    .foregroundStyle(Palette.tertiaryForeground)

                if showsLinkedBlockSection {
                    linkedBlockSection
                }

                if hasMetaRow {
                    HStack(spacing: 6 * layoutScale) {
                        if task.recurrence.isRepeating {
                            metaChip(task.recurrence.displayName, icon: "repeat")
                        }

                        if reminderCount > 0 {
                            metaChip("\(reminderCount)", icon: "bell")
                        }

                        if !showsLinkedBlockSection, let linkedTitle = linkedBlockChipText {
                            metaChip(linkedTitle, icon: "link")
                                .frame(maxWidth: 160 * layoutScale, alignment: .leading)
                        }

                        if let est = task.estimatedDuration {
                            metaChip(est, icon: "clock")
                        }

                        if task.isHabit, task.habitCurrentStreak > 0 {
                            metaChip("\(task.habitCurrentStreak) streak", icon: "flame.fill", foreground: .orange)
                        }

                        if let days = task.daysUntilMilestone {
                            metaChip("\(days)d left", icon: "flag", foreground: Palette.accent)
                        }

                        if task.isOverdue {
                            metaChip("Overdue", icon: "exclamationmark.circle.fill", foreground: Color(nsColor: Palette.agentDanger))
                        }
                    }
                    .lineLimit(1)
                }

                if !notesPreview.isEmpty {
                    Text(notesPreview)
                        .font(.system(size: subtitleFontSize))
                        .lineLimit(1)
                        .foregroundStyle(Palette.tertiaryForeground)
                }
            }
            .padding(.horizontal, 12 * layoutScale)
            .padding(.vertical, 11 * layoutScale)
        }
        .opacity(task.status == .completed ? 0.55 : 1)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10 * layoutScale)
                .fill(isHovering ? Palette.background : Palette.background.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10 * layoutScale)
                .stroke(Palette.border.opacity(isHovering ? 0.4 : 0.16), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(isHovering ? 0.08 : 0.02),
            radius: isHovering ? 9 * layoutScale : 3 * layoutScale,
            x: 0,
            y: isHovering ? 4 * layoutScale : 1 * layoutScale
        )
        .contentShape(RoundedRectangle(cornerRadius: 10 * layoutScale))
        .pointingHandCursor()
        .onTapGesture { onEdit(task) }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .contextMenu {
            if task.status == .pending {
                Button("Edit") { onEdit(task) }
                Button("Complete") { onComplete(task.id) }
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
