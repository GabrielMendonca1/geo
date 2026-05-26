import SwiftUI

struct TaskNodeView: View {
    let block: BlockEntity
    @ObservedObject var viewModel: BlocksViewModel
    var onOpenRawEditor: () -> Void = {}

    @Environment(\.appEnvironment) private var appEnvironment

    @State private var doc: TaskNodeDocument = .empty
    @State private var currentTurnIndex: Int = 0
    @State private var briefDraft: String = ""
    @State private var acceptanceDraft: String = ""
    @State private var composerText: String = ""
    @State private var specSaveTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @State private var isSubmitting: Bool = false
    @State private var hasLoaded: Bool = false
    @State private var linkedIssue: AIIssue? = nil
    @State private var projectName: String? = nil
    @State private var toolCalls: [AIToolCall] = []
    @State private var pendingPrompt: String? = nil
    @State private var pollTask: Task<Void, Never>? = nil
    @State private var lastParsedMarkdown: String = ""
    @State private var lastToolCallCount: Int = 0

    @FocusState private var briefFocused: Bool
    @FocusState private var acceptanceFocused: Bool
    @FocusState private var composerFocused: Bool

    private var liveBlock: BlockEntity {
        viewModel.block(withID: block.id) ?? block
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: 1)
            IssueSidebar(
                linkedIssue: linkedIssue,
                projectName: projectName,
                toolCalls: toolCalls,
                agentKind: agentKindFromIssue(),
                statusState: statusState,
                statusLabel: statusLabel,
                statusIcon: statusIcon,
                statusColor: statusColor,
                onUpdateState: { state in
                    guard let issueID = linkedIssue?.id else { return }
                    let environment = appEnvironment
                    Task { @MainActor in
                        _ = await environment.aiRepository.updateIssueState(issueID: issueID, state: state)
                    }
                },
                onUpdatePriority: { priority in
                    guard let issueID = linkedIssue?.id else { return }
                    let environment = appEnvironment
                    Task { @MainActor in
                        _ = await environment.aiRepository.setIssuePriority(issueID: issueID, priority: priority)
                    }
                },
                onUpdateModel: { model in
                    guard let issueID = linkedIssue?.id else { return }
                    let environment = appEnvironment
                    Task { @MainActor in
                        _ = await environment.aiRepository.setIssueModel(issueID: issueID, model: model)
                    }
                },
                onUpdateEffort: { effort in
                    guard let issueID = linkedIssue?.id else { return }
                    let environment = appEnvironment
                    Task { @MainActor in
                        _ = await environment.aiRepository.setIssueEffort(issueID: issueID, effort: effort)
                    }
                },
                defaultModelDisplay: resolvedDefaultModelDisplay(),
                defaultEffortDisplay: "medium"
            )
            .frame(width: 248)
        }
        .background(Color(Palette.background))
        .frame(minWidth: 760, idealWidth: 1020, minHeight: 540, idealHeight: 760)
        .onAppear {
            reloadFromBlock(force: true)
            refreshIssue(immediate: true)
        }
        .onChange(of: liveBlock.markdown) { _, _ in
            reloadFromBlock(force: false)
            refreshIssue()
        }
        .onChange(of: doc.reports.count) { _, _ in
            pendingPrompt = nil
        }
        .onChange(of: pendingPrompt) { _, newValue in
            pollTask?.cancel()
            guard newValue != nil else { return }
            lastToolCallCount = toolCalls.count
            pollTask = Task { @MainActor in
                while !Task.isCancelled {
                    refreshIssue(immediate: true)
                    let active = toolCalls.count > lastToolCallCount
                    lastToolCallCount = toolCalls.count
                    let nanos: UInt64 = active ? 250_000_000 : 1_500_000_000
                    try? await Task.sleep(nanoseconds: nanos)
                }
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            specSaveTask?.cancel()
            pollTask?.cancel()
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Color.primary.opacity(0.05)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    titleSection
                    descriptionSection
                    AcceptanceList(
                        draft: $acceptanceDraft,
                        focused: $acceptanceFocused,
                        onChange: { scheduleSpecSave() },
                        onToggle: { idx in toggleAcceptanceItem(at: idx) }
                    )
                    if let progressItems = TaskNodeDocument.parseChecklistItems(doc.progress ?? "", strict: true), !progressItems.isEmpty {
                        progressSection(items: progressItems)
                    }
                    if !doc.reports.isEmpty, let report = currentReport {
                        turnsDivider
                        TurnSection(
                            report: report,
                            turnIndex: currentTurnIndex,
                            linkedIssueState: linkedIssue?.state,
                            onApplyNextState: { state in
                                guard let issueID = linkedIssue?.id else { return }
                                let environment = appEnvironment
                                Task { @MainActor in
                                    _ = await environment.aiRepository.updateIssueState(issueID: issueID, state: state)
                                }
                            }
                        )
                    }
                    if let pendingPrompt {
                        if doc.reports.isEmpty {
                            turnsDivider
                        }
                        PendingTurnBubble(
                            prompt: pendingPrompt,
                            turnNumber: doc.reports.count + 1,
                            agentKind: agentKindFromIssue(),
                            toolCalls: toolCalls
                        )
                    } else if doc.reports.isEmpty {
                        emptyTurnsHint
                    }
                }
                .padding(.horizontal, 56)
                .padding(.top, 40)
                .padding(.bottom, 48)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            PromptComposer(
                text: $composerText,
                focused: $composerFocused,
                placeholder: composerPlaceholder,
                canSubmit: canSubmit,
                onSubmit: { submit() }
            )
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            breadcrumb
            Spacer(minLength: 12)
            if doc.reports.count > 1 {
                turnPaginator
            }
            topActions
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(height: 48)
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            if let projectName {
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(projectName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                chevronSeparator
            }
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(identifierText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.78))
            }
        }
    }

    private var chevronSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private var turnPaginator: some View {
        HStack(spacing: 8) {
            Text("Turn \(currentTurnIndex + 1) / \(doc.reports.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(spacing: 1) {
                Button {
                    if currentTurnIndex > 0 { currentTurnIndex -= 1 }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(currentTurnIndex > 0 ? 0.65 : 0.3))
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(currentTurnIndex <= 0)
                .keyboardShortcut("[", modifiers: .command)

                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: 14)

                Button {
                    if currentTurnIndex < doc.reports.count - 1 { currentTurnIndex += 1 }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(currentTurnIndex < doc.reports.count - 1 ? 0.65 : 0.3))
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(currentTurnIndex >= doc.reports.count - 1)
                .keyboardShortcut("]", modifiers: .command)
            }
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private var topActions: some View {
        HStack(spacing: 4) {
            Button {
                onOpenRawEditor()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Markdown")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.primary.opacity(0.78))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Open raw markdown editor")
        }
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayedTitle)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let createdAt = linkedIssue?.createdAt {
                HStack(spacing: 6) {
                    Text("Created \(createdAt.formatted(date: .abbreviated, time: .omitted))")
                    if !doc.reports.isEmpty {
                        Text("·")
                        Text("\(doc.reports.count) turn\(doc.reports.count == 1 ? "" : "s")")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var displayedTitle: String {
        if let issueTitle = linkedIssue?.title.trimmingCharacters(in: .whitespacesAndNewlines), !issueTitle.isEmpty {
            return issueTitle
        }
        let raw = liveBlock.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        let titleLine = doc.titleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if titleLine.hasPrefix("# ") {
            return String(titleLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Untitled Task"
    }

    private var identifierText: String {
        linkedIssue?.identifier ?? "—"
    }

    // MARK: - Description / Spec

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BRIEF")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            descriptionBody
        }
    }

    @ViewBuilder
    private var descriptionBody: some View {
        if briefFocused {
            TextEditor(text: $briefDraft)
                .focused($briefFocused)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 22)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: briefDraft) { _, _ in scheduleSpecSave() }
        } else if briefDraft.isEmpty {
            Text("Add description…")
                .font(.system(size: 14).italic())
                .foregroundStyle(.secondary)
                .opacity(0.55)
                .padding(.vertical, 8)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.iBeam.push() } else { NSCursor.pop() }
                }
                .onTapGesture { briefFocused = true }
        } else {
            renderMarkdownPreserving(briefDraft)
                .padding(.vertical, 8)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { briefFocused = true })
        }
    }

    @ViewBuilder
    private func renderMarkdownPreserving(_ markdown: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: 14))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(markdown)
                .font(.system(size: 14))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Turn divider

    private var turnsDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.top, 8)
    }

    private var currentReport: TaskNodeReport? {
        let reports = doc.reports
        guard !reports.isEmpty else { return nil }
        return reports[min(max(currentTurnIndex, 0), reports.count - 1)]
    }

    // MARK: - Composer

    private var composerPlaceholder: String {
        let agentName = agentKindFromIssue()?.label ?? "Claude Code"
        return doc.reports.isEmpty
            ? "Send a prompt to \(agentName)…"
            : "Reply to \(agentName)…"
    }

    private var canSubmit: Bool {
        !isSubmitting && !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Agent kind

    private func agentKindFromIssue() -> AIAgentKind? {
        if let raw = linkedIssue?.symphonyAgent?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty,
           let kind = AIAgentKind(rawValue: raw) {
            return kind
        }
        if let lastReport = doc.reports.last { return lastReport.agentKind }
        return .pi
    }

    private func resolvedDefaultModelDisplay() -> String {
        let raw = UserDefaults.standard.string(forKey: NanoProviderStore.defaultsKey) ?? ""
        switch NanoProvider(rawValue: raw) ?? .claude {
        case .claude: return "Opus"
        case .codex:  return "GPT-5"
        }
    }

    // MARK: - Status helpers

    private var statusState: String {
        linkedIssue?.state ?? extractStateFromMarkdown() ?? "Backlog"
    }

    private var statusLabel: String { statusState }

    private var statusColor: Color {
        switch statusState.lowercased() {
        case "backlog": return Color(red: 0.60, green: 0.60, blue: 0.60)
        case "todo": return Color(red: 0.40, green: 0.45, blue: 0.55)
        case "in progress", "in-progress", "in_progress": return Color(red: 0.96, green: 0.72, blue: 0.12)
        case "human review", "human-review", "review": return Color(red: 0.95, green: 0.55, blue: 0.18)
        case "done", "merged", "closed": return Color(red: 0.22, green: 0.75, blue: 0.36)
        case "canceled", "cancelled": return Color(red: 0.55, green: 0.55, blue: 0.55)
        default: return Color(red: 0.55, green: 0.55, blue: 0.55)
        }
    }

    private var statusIcon: String {
        switch statusState.lowercased() {
        case "backlog": return "circle.dashed"
        case "todo": return "circle"
        case "in progress", "in-progress", "in_progress": return "circle.bottomhalf.filled"
        case "human review", "human-review", "review": return "exclamationmark.circle"
        case "done", "merged", "closed": return "checkmark.circle.fill"
        case "canceled", "cancelled": return "minus.circle.fill"
        default: return "circle"
        }
    }

    private func extractStateFromMarkdown() -> String? {
        let markdown = liveBlock.markdown
        guard markdown.hasPrefix("---\n") else { return nil }
        let lines = markdown.components(separatedBy: "\n")
        var idx = 1
        while idx < lines.count {
            let stripped = lines[idx].trimmingCharacters(in: .whitespaces)
            if stripped == "---" { return nil }
            if stripped.hasPrefix("state:") {
                let value = stripped.dropFirst("state:".count)
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
            idx += 1
        }
        return nil
    }

    // MARK: - Acceptance toggle

    private func toggleAcceptanceItem(at index: Int) {
        let lines = acceptanceDraft.components(separatedBy: "\n")
        var checkboxLineIndices: [Int] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [") || trimmed.hasPrefix("* [") {
                checkboxLineIndices.append(i)
            }
        }
        guard index < checkboxLineIndices.count else { return }
        let lineIdx = checkboxLineIndices[index]
        var line = lines[lineIdx]
        if let openRange = line.range(of: "[ ]") {
            line.replaceSubrange(openRange, with: "[x]")
        } else if let closedRange = line.range(of: "[x]") ?? line.range(of: "[X]") {
            line.replaceSubrange(closedRange, with: "[ ]")
        }
        var newLines = lines
        newLines[lineIdx] = line
        acceptanceDraft = newLines.joined(separator: "\n")
        scheduleSpecSave()
        maybeAutoComplete()
    }

    private func maybeAutoComplete() {
        guard let items = TaskNodeDocument.parseChecklistItems(acceptanceDraft, strict: false), !items.isEmpty else { return }
        guard items.allSatisfy({ $0.done }) else { return }
        guard let issue = linkedIssue else { return }
        let currentState = issue.state.lowercased()
        let terminal: Set<String> = ["done", "merging", "merged", "closed", "canceled", "cancelled"]
        if terminal.contains(currentState) { return }
        let issueID = issue.id
        let environment = appEnvironment
        Task { @MainActor in
            _ = await environment.aiRepository.updateIssueState(issueID: issueID, state: "Done")
        }
    }

    // MARK: - Progress

    private func progressSection(items: [TaskNodeDocument.ChecklistItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROGRESS")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { idx in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: items[idx].done ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(items[idx].done ? Color.accentColor.opacity(0.9) : .secondary)
                        Text(items[idx].text)
                            .font(.system(size: 13))
                            .foregroundStyle(items[idx].done ? .secondary : .primary)
                            .strikethrough(items[idx].done, color: .secondary)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Empty state

    private var emptyTurnsHint: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Spacer()
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("No agent turns yet")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            VStack(spacing: 8) {
                ForEach(Array(suggestedPrompts().enumerated()), id: \.offset) { _, suggestion in
                    Button {
                        composerText = suggestion.prefill
                        composerFocused = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: suggestion.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(suggestion.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.82))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 16)
    }

    private struct SuggestedPrompt {
        let label: String
        let icon: String
        let prefill: String
    }

    private func suggestedPrompts() -> [SuggestedPrompt] {
        var out: [SuggestedPrompt] = []
        let brief = (doc.brief ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !brief.isEmpty {
            out.append(SuggestedPrompt(
                label: "Start from the brief",
                icon: "text.alignleft",
                prefill: "Read the brief and begin work:\n\n\(brief)"
            ))
        }
        if let items = TaskNodeDocument.parseChecklistItems(acceptanceDraft, strict: false) {
            let open = items.filter { !$0.done }
            if !open.isEmpty {
                let list = open.map { "- \($0.text)" }.joined(separator: "\n")
                out.append(SuggestedPrompt(
                    label: "Address acceptance criteria",
                    icon: "checklist",
                    prefill: "Address the following acceptance criteria:\n\n\(list)"
                ))
            }
        }
        out.append(SuggestedPrompt(
            label: "Explain the workspace",
            icon: "questionmark.circle",
            prefill: "Give me a tour of this workspace: what files exist, what the entry points are, and what state the work is in."
        ))
        return Array(out.prefix(3))
    }

    // MARK: - Reload / save

    private func reloadFromBlock(force: Bool) {
        let newMarkdown = liveBlock.markdown
        if !force && newMarkdown == lastParsedMarkdown { return }
        let parsed = TaskNodeDocument.parse(markdown: newMarkdown)
        lastParsedMarkdown = newMarkdown
        let prevReports = doc.reports.count
        doc = parsed
        if force {
            briefDraft = parsed.brief ?? ""
            acceptanceDraft = parsed.acceptance ?? ""
        }
        let landing: Int
        if parsed.reports.isEmpty {
            landing = 0
        } else if force {
            landing = parsed.reports.count - 1
        } else if parsed.reports.count > prevReports && currentTurnIndex == prevReports - 1 {
            landing = parsed.reports.count - 1
        } else {
            landing = min(currentTurnIndex, parsed.reports.count - 1)
        }
        currentTurnIndex = max(landing, 0)
        hasLoaded = true
    }

    private func refreshIssue(immediate: Bool = false) {
        refreshTask?.cancel()
        let blockID = liveBlock.id
        let environment = appEnvironment
        refreshTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            let snapshot = await environment.aiRepository.snapshot()
            if Task.isCancelled { return }
            let issue = snapshot.issues.first { $0.linkedBlockID == blockID }
            linkedIssue = issue
            projectName = snapshot.selectedProject?.name
            if let issue {
                let live = snapshot.liveSessions.first { $0.issueIdentifier == issue.identifier }
                if let live, !live.recentToolCalls.isEmpty {
                    toolCalls = live.recentToolCalls
                } else {
                    let attempt = snapshot.attempts.first { $0.issueID == issue.id }
                    toolCalls = attempt?.toolCalls ?? []
                }
            } else {
                toolCalls = []
            }
        }
    }

    private func scheduleSpecSave() {
        specSaveTask?.cancel()
        specSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            await persistSpec()
        }
    }

    private func persistSpec() async {
        let currentMarkdown = liveBlock.markdown
        var freshDoc = TaskNodeDocument.parse(markdown: currentMarkdown)
        freshDoc.brief = briefDraft.isEmpty ? nil : briefDraft
        freshDoc.acceptance = acceptanceDraft.isEmpty ? nil : acceptanceDraft
        let serialized = freshDoc.serialize()
        guard serialized != currentMarkdown else { return }
        try? await appEnvironment.blocksRepository.update(id: liveBlock.id, markdown: serialized)
    }

    private func submit() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        pendingPrompt = trimmed
        composerText = ""
        let blockID = liveBlock.id
        let environment = appEnvironment
        specSaveTask?.cancel()
        specSaveTask = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            await persistSpec()
            var freshDoc = TaskNodeDocument.parse(markdown: liveBlock.markdown)
            freshDoc.nextPrompt = trimmed
            let serialized = freshDoc.serialize()
            do {
                try await environment.blocksRepository.update(id: blockID, markdown: serialized)
            } catch {
                pendingPrompt = nil
                composerText = trimmed
                return
            }
            let snapshot = await environment.aiRepository.snapshot()
            if let issue = snapshot.issues.first(where: { $0.linkedBlockID == blockID }) {
                _ = await environment.aiRepository.updateIssueState(issueID: issue.id, state: "Todo")
            }
        }
    }
}

// MARK: - Document model

struct TaskNodeDocument: Equatable {
    var frontmatterRaw: String
    var titleLine: String
    var sections: [Section]

    struct Section: Equatable, Identifiable {
        var id: String { heading }
        var heading: String
        var content: String
    }

    struct ChecklistItem {
        var text: String
        var done: Bool
    }

    static let empty = TaskNodeDocument(frontmatterRaw: "", titleLine: "", sections: [])

    var brief: String? {
        get { sectionContent(forHeading: "## Brief") }
        set { setSection(heading: "## Brief", content: newValue) }
    }

    var acceptance: String? {
        get {
            sectionContent(forHeading: "## Acceptance Criteria") ??
            sectionContent(forHeading: "## Acceptance")
        }
        set {
            if sections.contains(where: { $0.heading == "## Acceptance Criteria" }) {
                setSection(heading: "## Acceptance Criteria", content: newValue)
                pruneEmptySection(heading: "## Acceptance")
            } else if sections.contains(where: { $0.heading == "## Acceptance" }) {
                setSection(heading: "## Acceptance", content: newValue)
            } else if newValue != nil {
                setSection(heading: "## Acceptance Criteria", content: newValue)
            }
        }
    }

    private mutating func pruneEmptySection(heading: String) {
        if let idx = sections.firstIndex(where: {
            $0.heading == heading &&
            $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            sections.remove(at: idx)
        }
    }

    var nextPrompt: String? {
        get { sectionContent(forHeading: "## Next Prompt") }
        set { setSection(heading: "## Next Prompt", content: newValue) }
    }

    var reports: [TaskNodeReport] {
        var result: [TaskNodeReport] = []
        var idx = 0
        while idx < sections.count {
            let section = sections[idx]
            if section.heading.hasPrefix("## Agent Report") {
                var body = section.content
                var nextIdx = idx + 1
                while nextIdx < sections.count {
                    let h = sections[nextIdx].heading
                    if TaskNodeDocument.isTopLevelHeading(h) { break }
                    body += "\n\n" + h + "\n" + sections[nextIdx].content
                    nextIdx += 1
                }
                if let report = TaskNodeReport(heading: section.heading, body: body) {
                    result.append(report)
                }
                idx = nextIdx
            } else {
                idx += 1
            }
        }
        return result
    }

    static func isTopLevelHeading(_ heading: String) -> Bool {
        let lower = heading.lowercased()
        return lower.hasPrefix("## agent report") ||
               lower.hasPrefix("## brief") ||
               lower.hasPrefix("## acceptance") ||
               lower.hasPrefix("## next prompt") ||
               lower.hasPrefix("## progress")
    }

    var progress: String? {
        get { sectionContent(forHeading: "## Progress") }
    }

    private func sectionContent(forHeading heading: String) -> String? {
        let match = sections.first { $0.heading == heading }
        let value = match?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private mutating func setSection(heading: String, content: String?) {
        if let idx = sections.firstIndex(where: { $0.heading == heading }) {
            sections[idx].content = content ?? ""
            return
        }
        guard let body = content, !body.isEmpty else { return }
        let insertAt = firstReportIndex() ?? sections.count
        sections.insert(Section(heading: heading, content: body), at: insertAt)
    }

    private func firstReportIndex() -> Int? {
        sections.firstIndex { $0.heading.hasPrefix("## Agent Report") }
    }

    static func parse(markdown: String) -> TaskNodeDocument {
        var doc = TaskNodeDocument.empty
        var bodyMarkdown = markdown
        if bodyMarkdown.hasPrefix("---\n") {
            let lines = bodyMarkdown.components(separatedBy: "\n")
            var closeIndex: Int?
            for idx in 1..<lines.count {
                if lines[idx].trimmingCharacters(in: .whitespaces) == "---" {
                    closeIndex = idx
                    break
                }
            }
            if let closeIndex {
                let fmLines = Array(lines[0...closeIndex])
                doc.frontmatterRaw = fmLines.joined(separator: "\n") + "\n"
                let remainder = Array(lines.dropFirst(closeIndex + 1))
                bodyMarkdown = remainder.joined(separator: "\n")
                while bodyMarkdown.hasPrefix("\n") { bodyMarkdown.removeFirst() }
            }
        }
        let lines = bodyMarkdown.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("# ") && !line.hasPrefix("## ") && doc.titleLine.isEmpty {
                doc.titleLine = line
                index += 1
                continue
            }
            if line.hasPrefix("## ") {
                let heading = line
                index += 1
                var collected: [String] = []
                while index < lines.count {
                    let next = lines[index]
                    if next.hasPrefix("## ") { break }
                    if next.hasPrefix("# ") && !next.hasPrefix("## ") { break }
                    collected.append(next)
                    index += 1
                }
                let content = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                doc.sections.append(Section(heading: heading, content: content))
                continue
            }
            index += 1
        }
        return doc
    }

    func serialize() -> String {
        var out = frontmatterRaw
        if !titleLine.isEmpty {
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            out += titleLine + "\n"
        }
        for section in sections {
            out += "\n" + section.heading + "\n"
            if !section.content.isEmpty {
                out += section.content + "\n"
            }
        }
        return out
    }

    static func parseChecklistItems(_ text: String, strict: Bool) -> [ChecklistItem]? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        let lines = trimmedText.components(separatedBy: "\n")
        var items: [ChecklistItem] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("* [ ]") {
                items.append(ChecklistItem(
                    text: String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces),
                    done: false
                ))
            } else if trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") ||
                        trimmed.hasPrefix("* [x]") || trimmed.hasPrefix("* [X]") {
                items.append(ChecklistItem(
                    text: String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces),
                    done: true
                ))
            } else if !strict, trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                items.append(ChecklistItem(
                    text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                    done: false
                ))
            } else {
                return nil
            }
        }
        return items.isEmpty ? nil : items
    }
}

struct TaskNodeReport: Identifiable, Equatable {
    let id: String
    let agentLabel: String?
    let agentKind: AIAgentKind?
    let timestamp: String?
    let timestampDate: Date?
    let prompt: String?
    let body: String

    init?(heading: String, body: String) {
        let prefix = "## Agent Report"
        guard heading.hasPrefix(prefix) else { return nil }
        var trailing = String(heading.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        while trailing.hasPrefix("-") {
            trailing.removeFirst()
            trailing = trailing.trimmingCharacters(in: .whitespaces)
        }
        var label: String? = nil
        var ts: String? = nil
        if !trailing.isEmpty {
            if let range = trailing.range(of: " - ") {
                let a = String(trailing[trailing.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let b = String(trailing[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if !a.isEmpty { label = a }
                if !b.isEmpty { ts = b }
            } else {
                label = trailing
            }
        }
        let kind: AIAgentKind?
        if let l = label?.lowercased(), l.contains("pi") || l.contains("claude") || l.contains("codex") {
            kind = .pi
        } else {
            kind = nil
        }
        let split = TaskNodeReport.extractPromptAndBody(from: body)
        let trimmedBody = split.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty,
              trimmedBody.lowercased() != "no agent report yet." else { return nil }
        self.id = ts ?? heading
        self.agentLabel = label
        self.agentKind = kind
        self.timestamp = ts
        self.timestampDate = ts.flatMap { ISO8601DateFormatter().date(from: $0) }
        self.prompt = split.prompt
        self.body = trimmedBody
    }

    static func extractPromptAndBody(from content: String) -> (prompt: String?, body: String) {
        let lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty,
              lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("> Prompt:") else {
            return (nil, content)
        }
        var promptLines: [String] = []
        var idx = 1
        while idx < lines.count {
            let stripped = lines[idx].trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix(">") {
                var rest = String(stripped.dropFirst())
                if rest.hasPrefix(" ") { rest.removeFirst() }
                promptLines.append(rest)
                idx += 1
            } else {
                break
            }
        }
        let promptText = promptLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyText = lines.dropFirst(idx).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (promptText.isEmpty ? nil : promptText, bodyText)
    }
}

enum TaskNodeDetector {
    static func isTaskNode(markdown: String) -> Bool {
        let lines = markdown.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("## Next Prompt") { return true }
            if line.hasPrefix("## Agent Report") { return true }
            if line.hasPrefix("symphony_agent:") { return true }
            if line.hasPrefix("symphony_model:") { return true }
            if line.hasPrefix("symphony_effort:") { return true }
        }
        return false
    }
}
