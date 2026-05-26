import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func openPiLoginInTerminal() {
    let source = """
    tell application "Terminal"
        activate
        do script "echo '→ Type  /login  in the pi editor below, then pick Anthropic Claude Pro/Max.' && pi"
    end tell
    """
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
}

struct AIPane: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @StateObject private var viewModel = AIViewModel()

    var body: some View {
        Pane {
            Group {
                if let snapshot = viewModel.snapshot {
                    AIDashboard(snapshot: snapshot, viewModel: viewModel)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(Palette.background))
        }
        .task {
            viewModel.bindIfNeeded(repository: appEnvironment.aiRepository)
        }
    }
}

private struct AIDashboard: View {
    let snapshot: AISnapshot
    @ObservedObject var viewModel: AIViewModel
    @State private var showCreateSheet: Bool = false
    @State private var draggedIssueID: String?

    private var hiddenColumns: [AIBoardColumn] {
        let visibleSet = Set(AIBoardStateNames.visible.map { $0.lowercased() })
        let known = Set((AIBoardStateNames.visible + AIBoardStateNames.hidden).map { $0.lowercased() })
        let extraStates = snapshot.issues
            .map { AIBoardStateNames.canonical($0.state) }
            .filter { !known.contains($0.lowercased()) }
            .sorted()
        let candidate = AIBoardStateNames.hidden + extraStates
        let orderedStates = candidate.reduce(into: [String]()) { result, state in
            if visibleSet.contains(state.lowercased()) { return }
            if !result.contains(where: { $0.caseInsensitiveCompare(state) == .orderedSame }) {
                result.append(state)
            }
        }
        return orderedStates.map { state in
            AIBoardColumn(
                state: state,
                issues: snapshot.issues.filter { issue in
                    AIBoardStateNames.canonical(issue.state).caseInsensitiveCompare(state) == .orderedSame
                }
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AIHeader(
                snapshot: snapshot,
                viewModel: viewModel,
                showCreateSheet: $showCreateSheet,
                hiddenColumns: hiddenColumns,
                draggedIssueID: $draggedIssueID
            )
            Divider().opacity(0.4)
            AIBoard(
                snapshot: snapshot,
                viewModel: viewModel,
                draggedIssueID: $draggedIssueID,
                showCreateIssue: { state in
                    viewModel.selectedState = state
                    showCreateSheet = true
                }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.4)
            AIFooter(snapshot: snapshot, viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showCreateSheet) {
            AICreateIssueSheet(viewModel: viewModel)
        }
    }
}

private struct AIHeader: View {
    let snapshot: AISnapshot
    @ObservedObject var viewModel: AIViewModel
    @Binding var showCreateSheet: Bool
    let hiddenColumns: [AIBoardColumn]
    @Binding var draggedIssueID: String?

    private var headerError: String? {
        snapshot.workflow.parseError ?? snapshot.workflow.config.dispatchValidationError
    }

    private var runtimeError: String? {
        guard let raw = viewModel.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private var projectTitle: String {
        viewModel.selectedProject?.name ?? "No project"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AIPillLabel(title: "Tasks", systemName: "checklist", selected: true)
                AIPillButton(title: "New task", systemName: "plus") {
                    viewModel.selectedState = "Backlog"
                    showCreateSheet = true
                }
                if viewModel.availableAgentCount == 0 {
                    AIPillButton(title: "Sign in to pi", systemName: "key.fill") {
                        openPiLoginInTerminal()
                    }
                }

                Spacer(minLength: 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(hiddenColumns) { column in
                            AIHiddenStateChip(
                                column: column,
                                viewModel: viewModel,
                                draggedIssueID: $draggedIssueID
                            )
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if headerError != nil || runtimeError != nil {
                VStack(spacing: 4) {
                    if let headerError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text(headerError)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.orange.opacity(0.10))
                        )
                    }
                    if let runtimeError {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.octagon.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text(runtimeError)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            Button {
                                viewModel.errorMessage = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss")
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.red.opacity(0.10))
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .background(Color(Palette.secondaryBackground).opacity(0.25))
    }
}

private struct AIPillLabel: View {
    let title: String
    let systemName: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(selected ? Color.accentColor : Color.clear)
        .overlay(
            Capsule()
                .strokeBorder(selected ? Color.clear : Color.primary.opacity(0.16), lineWidth: 1.5)
        )
        .clipShape(Capsule())
    }
}

private struct AIPillButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Color.clear)
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1.5)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private enum AIBoardStateNames {
    static let visible = ["Backlog", "Todo", "In Progress", "Human Review"]
    static let hidden = ["Rework", "Merging", "Done", "Canceled", "Duplicate"]
    static let all = visible + hidden

    static func canonical(_ state: String) -> String {
        switch state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "backlog": return "Backlog"
        case "todo": return "Todo"
        case "in progress", "in-progress", "in_progress": return "In Progress"
        case "human review", "human-review", "human_review": return "Human Review"
        case "rework": return "Rework"
        case "merging", "merge": return "Merging"
        case "done", "closed": return "Done"
        case "canceled", "cancelled": return "Canceled"
        case "duplicate": return "Duplicate"
        default: return state
        }
    }
}

private struct AIBoard: View {
    let snapshot: AISnapshot
    @ObservedObject var viewModel: AIViewModel
    @Binding var draggedIssueID: String?
    let showCreateIssue: (String) -> Void

    private var boardIssues: [AIIssue] {
        snapshot.issues
    }

    private var visibleStates: [String] {
        let pinned = AIBoardStateNames.hidden.filter { viewModel.isHiddenStatePinned($0) }
        return AIBoardStateNames.visible + pinned
    }

    private var columns: [AIBoardColumn] {
        visibleStates.map(column)
    }

    var body: some View {
        GeometryReader { proxy in
            let boardSize = proxy.size
            let activeColumns = columns
            let columnCount = max(activeColumns.count, 1)
            let columnWidth = min(max((boardSize.width - 88) / CGFloat(min(max(columnCount, 1), 4)), 300), 390)
            let minColumnHeight = max(boardSize.height - 22, 360)

            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(activeColumns) { column in
                        AIColumnView(
                            column: column,
                            snapshot: snapshot,
                            viewModel: viewModel,
                            draggedIssueID: $draggedIssueID,
                            create: { showCreateIssue(column.state) }
                        )
                            .frame(width: columnWidth)
                            .frame(minHeight: minColumnHeight, alignment: .top)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(minWidth: boardSize.width, minHeight: boardSize.height, alignment: .topLeading)
            }
        }
        .background(Color(Palette.background))
    }

    private func column(for state: String) -> AIBoardColumn {
        AIBoardColumn(
            state: state,
            issues: boardIssues.filter { issue in
                AIBoardStateNames.canonical(issue.state).caseInsensitiveCompare(state) == .orderedSame
            }
        )
    }
}

private struct AIColumnView: View {
    let column: AIBoardColumn
    let snapshot: AISnapshot
    @ObservedObject var viewModel: AIViewModel
    @Binding var draggedIssueID: String?
    let create: () -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

    private var isOwnColumn: Bool {
        guard let draggedIssueID,
              let issue = snapshot.issues.first(where: { $0.id == draggedIssueID }) else { return false }
        return AIBoardStateNames.canonical(issue.state).caseInsensitiveCompare(column.state) == .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AIStateIcon(state: column.state)
                Text(column.state)
                    .font(.system(size: 16, weight: .semibold))
                Text("\(column.issues.count)")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Button(action: create) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Create task in \(column.state)")
            }
            .padding(.horizontal, 4)
            .frame(height: 36)

            LazyVStack(spacing: 8) {
                ForEach(column.issues) { issue in
                    AIIssueCard(
                        issue: issue,
                        isSelected: viewModel.selectedIssueID == issue.id,
                        runAttempt: runAttempt(for: issue.id),
                        liveSession: liveSession(for: issue.id),
                        canDispatch: viewModel.availableAgentCount > 0,
                        dispatch: { viewModel.dispatch(issueID: issue.id) },
                        move: { state in viewModel.updateIssueState(issueID: issue.id, state: state) },
                        stop: { viewModel.release(issueID: issue.id) },
                        openWorkspace: { viewModel.openWorkspace(issueID: issue.id) },
                        release: { viewModel.release(issueID: issue.id) },
                        delete: { viewModel.deleteIssue(issueID: issue.id) },
                        setModel: { model in viewModel.setIssueModel(issueID: issue.id, model: model) },
                        setEffort: { effort in viewModel.setIssueEffort(issueID: issue.id, effort: effort) },
                        openNode: {
                            viewModel.openLinkedNode(for: issue) { linkedBlockID in
                                MenuActions.openBlockEditor(linkedBlockID, openWindow: openWindow)
                            }
                        }
                    )
                    .scaleEffect(draggedIssueID == issue.id ? 0.98 : 1)
                    .opacity(draggedIssueID == issue.id ? 0.55 : 1)
                    .animation(.easeOut(duration: 0.12), value: draggedIssueID)
                    .draggable(issue.id) {
                        AIIssueDragPreview(issue: issue)
                            .onAppear { draggedIssueID = issue.id }
                    }
                }

                if column.issues.isEmpty || isDropTargeted {
                    AIDropPlaceholder(active: isDropTargeted && !isOwnColumn)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isDropTargeted && !isOwnColumn ? Color.accentColor.opacity(0.10) : Color.clear)
                .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isDropTargeted && !isOwnColumn ? Color.accentColor.opacity(0.6) : Color.clear,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
                .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        )
        .dropDestination(for: String.self) { items, _ in
            defer { draggedIssueID = nil }
            guard let id = items.first else { return false }
            if let issue = snapshot.issues.first(where: { $0.id == id }),
               AIBoardStateNames.canonical(issue.state).caseInsensitiveCompare(column.state) == .orderedSame {
                return false
            }
            viewModel.updateIssueState(issueID: id, state: column.state)
            return true
        } isTargeted: { hovering in
            isDropTargeted = hovering
        }
    }

    private func runAttempt(for issueID: String) -> AIRunAttempt? {
        snapshot.attempts.first { $0.issueID == issueID }
    }

    private func liveSession(for issueID: String) -> AILiveSession? {
        snapshot.liveSessions.first { $0.issueID == issueID }
    }
}

private struct AIIssueDragPreview: View {
    let issue: AIIssue

    var body: some View {
        HStack(spacing: 8) {
            AIStateIcon(state: issue.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.identifier)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(issue.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 280, alignment: .leading)
        .background(Color(Palette.secondaryBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 6)
    }
}

private struct AIDropPlaceholder: View {
    let active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(
                active ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])
            )
            .frame(height: active ? 56 : 36)
            .overlay {
                if active {
                    Text("Drop to move")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .animation(.easeOut(duration: 0.12), value: active)
    }
}

private struct AIIssueCard: View {
    let issue: AIIssue
    let isSelected: Bool
    let runAttempt: AIRunAttempt?
    let liveSession: AILiveSession?
    let canDispatch: Bool
    let dispatch: () -> Void
    let move: (String) -> Void
    let stop: () -> Void
    let openWorkspace: () -> Void
    let release: () -> Void
    let delete: () -> Void
    let setModel: (String?) -> Void
    let setEffort: (String?) -> Void
    let openNode: () -> Void
    @State private var isHovered: Bool = false

    private var runStatus: AIRunStatus? {
        guard let runAttempt else { return nil }
        if runAttempt.status.isActive { return runAttempt.status }
        if runAttempt.status == .failed || runAttempt.status == .timedOut || runAttempt.status == .stalled {
            return runAttempt.status
        }
        return nil
    }

    private var runError: String? {
        guard let runAttempt, runAttempt.status == .failed || runAttempt.status == .timedOut || runAttempt.status == .stalled else { return nil }
        return runAttempt.error
    }

    private var trackerURL: URL? {
        guard let raw = issue.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var isActive: Bool {
        liveSession != nil || (runStatus?.isActive ?? false)
    }

    private var accentColor: Color {
        guard let runStatus else {
            return liveSession != nil ? .blue : .clear
        }
        switch runStatus {
        case .preparing, .launching, .running:
            return .blue
        case .succeeded:
            return .green
        case .failed, .timedOut, .stalled:
            return .red
        case .retryQueued:
            return .orange
        case .canceled:
            return .clear
        }
    }

    private var displayedModel: String? {
        if let live = liveSession?.modelLabel, !live.isEmpty { return live }
        let pinned = issue.symphonyModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (pinned?.isEmpty ?? true) ? nil : pinned
    }

    private var displayedEffort: String? {
        let pinned = issue.symphonyEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (pinned?.isEmpty ?? true) ? nil : pinned
    }

    private var modelBinding: Binding<String?> {
        Binding(
            get: {
                let trimmed = issue.symphonyModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            },
            set: { newValue in setModel(newValue) }
        )
    }

    private var effortBinding: Binding<String?> {
        Binding(
            get: {
                let trimmed = issue.symphonyEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            },
            set: { newValue in setEffort(newValue) }
        )
    }

    private var agentMenu: some View {
        Menu {
            Picker("Model", selection: modelBinding) {
                Text("Default").tag(String?.none)
                Text("Opus").tag(String?.some("opus"))
                Text("Sonnet").tag(String?.some("sonnet"))
                Text("Haiku").tag(String?.some("haiku"))
            }
            Picker("Effort", selection: effortBinding) {
                Text("Default").tag(String?.none)
                Text("Low").tag(String?.some("low"))
                Text("Medium").tag(String?.some("medium"))
                Text("High").tag(String?.some("high"))
                Text("XHigh").tag(String?.some("xhigh"))
                Text("Max").tag(String?.some("max"))
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: AIAgentKind.pi.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AIAgentKind.pi.tint)
                Text(AIAgentKind.pi.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                if let model = displayedModel, !model.isEmpty {
                    Text(model)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                if let effort = displayedEffort, !effort.isEmpty {
                    Text(effort)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .menuIndicator(.hidden)
        .help("Agent settings")
    }

    private var activityLine: String? {
        let raw = liveSession?.lastMessage ?? liveSession?.lastEvent
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 7) {
                agentMenu
                if runStatus != nil || liveSession != nil {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 5, height: 5)
                        Text(runStatus?.label ?? "Active")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(accentColor.opacity(0.12))
                    )
                    .help(runError ?? runStatus?.label ?? "Active")
                }
                Spacer(minLength: 8)
                if let priority = issue.priority {
                    Text("P\(priority)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 18)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AIStateIcon(state: issue.state)
                Text(issue.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { openNode() }

            if let activityLine, isActive {
                HStack(spacing: 6) {
                    AIActivityShimmer()
                    Text(activityLine)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(activityLine)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        ))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.22), value: activityLine)
                .clipped()
            }

            if let runError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                    Text(runError)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if runError == "Run: pi /login" { openPiLoginInTerminal() }
                }
                .help(runError == "Run: pi /login" ? "Click to sign in to pi" : runError)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 6, x: 0, y: 2)
        .overlay(alignment: .topTrailing) {
            if isHovered {
                hoverActions
                    .padding(.top, 6)
                    .padding(.trailing, 6)
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 4) {
            if isActive {
                Button(action: stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .background(Circle().fill(Color.red.opacity(0.12)))
                .help("Stop run")
            } else {
                Button(action: dispatch) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .disabled(!canDispatch)
                .help("Run")
            }

            Button(action: openWorkspace) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(Color.primary.opacity(0.08)))
            .help("Open workspace")

            Menu {
                ForEach(AIBoardStateNames.all, id: \.self) { state in
                    Button {
                        move(state)
                    } label: {
                        Label(state, systemImage: state.caseInsensitiveCompare(issue.state) == .orderedSame ? "checkmark" : "circle")
                    }
                    .disabled(state.caseInsensitiveCompare(issue.state) == .orderedSame)
                }
                Divider()
                Button(role: .destructive, action: release) {
                    Label("Release claim", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive, action: delete) {
                    Label("Delete task", systemImage: "trash")
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .background(Circle().fill(Color.primary.opacity(0.08)))
            .help("Move")
        }
    }

    private var cardBackground: Color {
        isSelected ? Color.accentColor.opacity(0.08) : Color(Palette.secondaryBackground).opacity(0.78)
    }

    private var borderColor: Color {
        if isSelected { return Color.accentColor.opacity(0.7) }
        return Color.primary.opacity(0.075)
    }

    private var borderWidth: CGFloat {
        if isSelected { return 1.5 }
        return 1
    }

}

private struct AIActivityShimmer: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.85))
            .frame(width: 6, height: 6)
            .scaleEffect(0.7 + 0.45 * phase)
            .opacity(0.45 + 0.55 * phase)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
    }
}

private struct AIHiddenStateChip: View {
    let column: AIBoardColumn
    @ObservedObject var viewModel: AIViewModel
    @Binding var draggedIssueID: String?
    @State private var isDropTargeted = false

    private var isActiveDrag: Bool { draggedIssueID != nil }
    private var isPinned: Bool { viewModel.isHiddenStatePinned(column.state) }

    var body: some View {
        Button {
            viewModel.toggleHiddenState(column.state)
        } label: {
            HStack(spacing: 6) {
                AIStateIcon(state: column.state)
                Text(column.state)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(column.issues.count)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(isPinned ? Color.white.opacity(0.85) : .secondary)
            }
            .foregroundStyle(isPinned ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(width: 124, height: 28)
            .background(
                Capsule().fill(
                    isDropTargeted
                        ? Color.accentColor.opacity(0.18)
                        : (isPinned ? Color.accentColor : Color.clear)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isDropTargeted
                        ? Color.accentColor
                        : (isPinned ? Color.clear : Color.primary.opacity(isActiveDrag ? 0.35 : 0.16)),
                    lineWidth: isDropTargeted ? 1.5 : 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { items, _ in
            defer { draggedIssueID = nil }
            guard let id = items.first else { return false }
            if column.issues.contains(where: { $0.id == id }) {
                return false
            }
            viewModel.updateIssueState(issueID: id, state: column.state)
            return true
        } isTargeted: { hovering in
            isDropTargeted = hovering
        }
        .help(isPinned ? "Hide \(column.state) column" : "Show \(column.state) column")
    }
}

private struct AIStateIcon: View {
    let state: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 16)
    }

    private var symbolName: String {
        switch AIBoardStateNames.canonical(state) {
        case "Backlog": return "circle.dotted"
        case "Todo": return "circle"
        case "In Progress": return "circle.lefthalf.filled"
        case "Human Review": return "circle.circle"
        case "Rework": return "arrow.counterclockwise.circle"
        case "Merging": return "arrow.triangle.merge"
        case "Done": return "checkmark.circle.fill"
        case "Canceled": return "xmark.circle.fill"
        case "Duplicate": return "xmark.circle"
        default: return "circle"
        }
    }

    private var tint: Color {
        switch AIBoardStateNames.canonical(state) {
        case "In Progress": return .yellow
        case "Human Review": return .pink
        case "Rework": return .orange
        case "Merging": return .green
        case "Done": return .indigo
        case "Canceled", "Duplicate": return .secondary
        default: return .secondary
        }
    }
}

private struct AIFooter: View {
    let snapshot: AISnapshot
    @ObservedObject var viewModel: AIViewModel
    @State private var showLogPopover: Bool = false
    @State private var showRunningPopover: Bool = false
    @State private var showWorkspacesPopover: Bool = false

    private var errorRows: [LogRowModel] {
        LogRowModel.dedupe(logs: snapshot.logs.filter { $0.level != .info })
    }

    private var allRows: [LogRowModel] {
        LogRowModel.dedupe(logs: snapshot.logs)
    }

    private var pollText: String {
        guard let lastPollAt = snapshot.state.lastPollAt else { return "No poll yet" }
        let interval = Date().timeIntervalSince(lastPollAt)
        if interval < 60 { return "Last poll \(Int(interval))s ago" }
        if interval < 3600 { return "Last poll \(Int(interval / 60))m ago" }
        return "Last poll \(Int(interval / 3600))h ago"
    }

    private var errorCount: Int {
        snapshot.logs.filter { $0.level != .info }.count
    }

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(pollText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            FooterDot()

            Button {
                showLogPopover.toggle()
            } label: {
                Text(errorCount > 0 ? "\(errorCount) error\(errorCount == 1 ? "" : "s")" : "no errors")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(errorCount > 0 ? Color.red : .secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showLogPopover, arrowEdge: .top) {
                LogPopover(rows: errorCount > 0 ? errorRows : allRows)
            }

            FooterDot()

            Button {
                showRunningPopover.toggle()
            } label: {
                Text("\(snapshot.liveSessions.count) running")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .popover(isPresented: $showRunningPopover, arrowEdge: .top) {
                RunningSessionsPopover(sessions: snapshot.liveSessions)
            }

            FooterDot()

            Button {
                showWorkspacesPopover.toggle()
            } label: {
                Text("\(snapshot.workspaces.count) workspace\(snapshot.workspaces.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .popover(isPresented: $showWorkspacesPopover, arrowEdge: .top) {
                WorkspacesPopover(workspaces: snapshot.workspaces)
            }

            Spacer(minLength: 0)

            Text(snapshot.workflow.config.tracker.kind)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(height: 28)
        .background(Color(Palette.secondaryBackground).opacity(0.35))
    }
}

private struct FooterDot: View {
    var body: some View {
        Text("·")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary.opacity(0.6))
    }
}

private struct LogPopover: View {
    let rows: [LogRowModel]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if rows.isEmpty {
                    Text("No log entries.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        LogCompactRow(row: row)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 360)
        .frame(maxHeight: 320)
    }
}

private struct RunningSessionsPopover: View {
    let sessions: [AILiveSession]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if sessions.isEmpty {
                    Text("No running sessions.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions) { session in
                        HStack(spacing: 8) {
                            Text(session.issueIdentifier)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Spacer(minLength: 8)
                            Text(session.provider ?? session.agent.shortLabel)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 280)
        .frame(maxHeight: 280)
    }
}

private struct WorkspacesPopover: View {
    let workspaces: [AIWorkspace]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if workspaces.isEmpty {
                    Text("No workspaces.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(workspaces) { workspace in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.projectName ?? workspace.issueIdentifier)
                                .font(.system(size: 11, weight: .semibold))
                            Text(workspace.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .truncationMode(.middle)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 360)
        .frame(maxHeight: 320)
    }
}

private struct LogRowModel: Identifiable {
    let id: UUID
    let level: AILogLevel
    let message: String
    var earliestTimestamp: Date
    var latestTimestamp: Date
    var count: Int

    static func dedupe(logs: [AILogEntry]) -> [LogRowModel] {
        var result: [LogRowModel] = []
        for entry in logs {
            if var last = result.last, last.message == entry.message, last.level == entry.level {
                last.count += 1
                last.latestTimestamp = max(last.latestTimestamp, entry.timestamp)
                last.earliestTimestamp = min(last.earliestTimestamp, entry.timestamp)
                result[result.count - 1] = last
            } else {
                result.append(LogRowModel(
                    id: entry.id,
                    level: entry.level,
                    message: entry.message,
                    earliestTimestamp: entry.timestamp,
                    latestTimestamp: entry.timestamp,
                    count: 1
                ))
            }
        }
        return Array(result.prefix(40))
    }
}

private struct LogCompactRow: View {
    let row: LogRowModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.level.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(row.level.tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.message)
                        .font(.system(size: 12))
                        .lineLimit(2)
                    if row.count > 1 {
                        Text("× \(row.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(Self.timeFormatter.string(from: row.latestTimestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct AIBoardColumn: Identifiable {
    let state: String
    let issues: [AIIssue]

    var id: String { state.lowercased() }
}

private extension AIRunStatus {
    var isActive: Bool {
        switch self {
        case .preparing, .launching, .running:
            return true
        case .succeeded, .failed, .timedOut, .stalled, .canceled, .retryQueued:
            return false
        }
    }
}
