import AppKit
import Foundation
import os.log

private let aiLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "AI")

private struct AIAppConfig: Codable, Hashable {
    var workflow: AIConfig
    var promptTemplate: String
    var projectDiscovery: AIProjectDiscoveryConfig

    static func defaults(rootURL: URL) -> AIAppConfig {
        AIAppConfig(
            workflow: AIConfig.defaults(workflowDirectory: rootURL),
            promptTemplate: Self.defaultPromptTemplate,
            projectDiscovery: .defaults()
        )
    }

    private static var defaultPromptTemplate: String {
        """
        You are an autonomous coding agent launched by Geo.

        Issue: {{ issue.identifier }}
        Title: {{ issue.title }}
        State: {{ issue.state }}
        Attempt: {{ attempt }}

        Project: {{ project.name }}
        Project path: {{ project.path }}
        Workspace: {{ agent.workspace_path }}
        Report path: {{ agent.report_path }}

        Issue Node:
        {{ issue.node_markdown }}

        The user's request (under `## User Request` inside the Issue Node above) is your primary instruction. Execute it.

        `## Brief` and `## Acceptance Criteria` are optional context — they may be empty, placeholder text (e.g. "Write the task brief here."), or fully specified. Treat them as hints, not gates. Do not refuse, stall, or flag the run because Brief is unset or looks like a placeholder. Acceptance Criteria is human-owned; only the human edits those checkboxes.

        Work in the current project checkout when one exists. Keep changes scoped to this issue, avoid relying on AI repository Markdown skill files, validate pragmatically, and leave a concise handoff.

        Report format.

        Write a concise Markdown report to:
        {{ agent.report_path }}

        The FIRST section of the report MUST be `## Progress` — a markdown checklist describing the concrete steps you actually took during this turn. Use `- [x]` for completed steps and (rarely) `- [ ]` for steps you deliberately deferred. 5–12 items typical. Each item must be concrete and verifiable, e.g.:

        ## Progress
        - [x] Read auth.py to understand session handling
        - [x] Updated token rotation in session_handler.py line 42
        - [x] Wrote unit test in test_session.py for the new rotation
        - [x] Ran pytest tests/auth/ — all green
        - [x] Wrote handoff summary

        After `## Progress`, include: summary, files changed, validation, risks, and next recommended state.

        Formatting rules — the Geo viewer is a thin Markdown renderer:
        - Do NOT use Markdown tables (pipes/dashes). Use bullet lists. For `## Files Changed`, one bullet per file in the form `- path/to/file — what changed`.
        - Keep prose tight. Prefer 1–2 sentences per section over paragraphs.
        - For `## Next Recommended State`, the FIRST word of the section body must be the literal state name (one of: Backlog, Todo, In Progress, Human Review, Rework, Merging, Done, Canceled). The viewer parses this to surface a one-click transition button.
        """
    }
}

private struct AIProjectDiscoveryConfig: Codable, Hashable {
    var roots: [String]
    var selectedPath: String?
    var maxDepth: Int
    var maxEntriesPerDirectory: Int
    var rescanIntervalMS: Int

    static func defaults() -> AIProjectDiscoveryConfig {
        AIProjectDiscoveryConfig(
            roots: ["~/ARC", "~/Programming", "~/Developer", "~/Code", "~/Projects"],
            selectedPath: nil,
            maxDepth: 5,
            maxEntriesPerDirectory: 400,
            rescanIntervalMS: 120_000
        )
    }
}

private struct AIDetectedPiRuntime: Codable, Hashable {
    var executablePath: String?
    var version: String?
    var authConfigured: Bool
    var statusDetail: String?

    var isAvailable: Bool { executablePath?.isEmpty == false && authConfigured }
}

private struct AIDetectedHermesRuntime: Codable, Hashable {
    var executablePath: String?
    var lastCheckedAt: Date?
    var isAvailable: Bool { executablePath?.isEmpty == false }
}

private struct AIPreparedAgentWorkspace: Hashable {
    var kind: AIAgentKind
    var rootURL: URL
    var workingDirectoryURL: URL
    var prompt: String
}

private struct AIProjectRunMetadata: Codable, Hashable {
    var issueID: String
    var issueIdentifier: String
    var agent: String?
    var project: AIDiscoveredProject
    var workspacePath: String
    var workingDirectoryPath: String
    var createdAt: Date
}

private struct AIParsedWorkflowFile {
    var config: AIAppConfig
    var parseError: String?
}

enum AISimpleYAMLParser {
    static func parse(_ text: String) throws -> [String: Any] {
        let lines = text.components(separatedBy: "\n")
        var index = 0
        let result = try parseBlock(lines: lines, index: &index, parentIndent: -1)
        return result as? [String: Any] ?? [:]
    }

    private static func parseBlock(lines: [String], index: inout Int, parentIndent: Int) throws -> Any {
        var dict: [String: Any] = [:]
        var list: [Any] = []
        var mode: BlockMode = .unknown

        while index < lines.count {
            let raw = lines[index]
            if isIgnorable(raw) { index += 1; continue }

            let indent = leadingSpaces(of: raw)
            if indent <= parentIndent { break }

            let line = String(raw.dropFirst(indent))
            if line.hasPrefix("- ") {
                if mode == .unknown { mode = .list }
                guard mode == .list else { throw yamlError("Mixed map/list at line \(index + 1).") }
                let content = String(line.dropFirst(2))
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    index += 1
                    let child = try parseBlock(lines: lines, index: &index, parentIndent: indent)
                    list.append(child)
                } else if let colonRange = unquotedColonRange(in: content) {
                    var entry: [String: Any] = [:]
                    let key = unquoteString(String(content[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces))
                    let valuePart = content[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
                    if valuePart.isEmpty {
                        index += 1
                        let child = try parseBlock(lines: lines, index: &index, parentIndent: indent)
                        entry[key] = child
                    } else {
                        entry[key] = try parseScalarOrFlow(valuePart)
                        index += 1
                    }
                    while index < lines.count {
                        let next = lines[index]
                        if isIgnorable(next) { index += 1; continue }
                        let nextIndent = leadingSpaces(of: next)
                        if nextIndent <= indent { break }
                        let nextLine = String(next.dropFirst(nextIndent))
                        guard let nextColon = unquotedColonRange(in: nextLine) else { break }
                        let key = unquoteString(String(nextLine[..<nextColon.lowerBound]).trimmingCharacters(in: .whitespaces))
                        let value = nextLine[nextColon.upperBound...].trimmingCharacters(in: .whitespaces)
                        if value.isEmpty {
                            index += 1
                            entry[key] = try parseBlock(lines: lines, index: &index, parentIndent: nextIndent)
                        } else {
                            entry[key] = try parseScalarOrFlow(value)
                            index += 1
                        }
                    }
                    list.append(entry)
                } else {
                    list.append(try parseScalarOrFlow(trimmed))
                    index += 1
                }
            } else if let colonRange = unquotedColonRange(in: line) {
                if mode == .unknown { mode = .map }
                guard mode == .map else { throw yamlError("Mixed map/list at line \(index + 1).") }
                let key = unquoteString(String(line[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces))
                let value = line[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    index += 1
                    dict[key] = try parseBlock(lines: lines, index: &index, parentIndent: indent)
                } else {
                    dict[key] = try parseScalarOrFlow(value)
                    index += 1
                }
            } else {
                throw yamlError("Unrecognized line at \(index + 1): \(raw)")
            }
        }

        switch mode {
        case .list: return list
        case .map, .unknown: return dict
        }
    }

    private static func parseScalarOrFlow(_ raw: String) throws -> Any {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let inner = String(trimmed.dropFirst().dropLast())
            return splitFlowList(inner).map { (item: String) -> Any in
                let trimmedItem = item.trimmingCharacters(in: .whitespaces)
                return (try? parseScalarOrFlow(trimmedItem)) ?? trimmedItem
            }
        }
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            let inner = String(trimmed.dropFirst().dropLast())
            var result: [String: Any] = [:]
            for entry in splitFlowList(inner) {
                guard let colon = unquotedColonRange(in: entry) else { continue }
                let key = unquoteString(String(entry[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces))
                let value = String(entry[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                result[key] = (try? parseScalarOrFlow(value)) ?? value
            }
            return result
        }
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        if let int = Int(trimmed) { return int }
        if let double = Double(trimmed) { return double }
        return unquoteString(trimmed)
    }

    private static func splitFlowList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var depth = 0
        var inString: Character? = nil
        for c in text {
            if let q = inString {
                current.append(c)
                if c == q { inString = nil }
                continue
            }
            switch c {
            case "\"", "'": inString = c; current.append(c)
            case "[", "{": depth += 1; current.append(c)
            case "]", "}": depth -= 1; current.append(c)
            case "," where depth == 0:
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { items.append(trimmed) }
                current = ""
            default: current.append(c)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { items.append(last) }
        return items
    }

    private static func unquoteString(_ text: String) -> String {
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func unquotedColonRange(in text: String) -> Range<String.Index>? {
        var inString: Character? = nil
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if let q = inString {
                if c == q { inString = nil }
            } else if c == "\"" || c == "'" {
                inString = c
            } else if c == ":" {
                let after = text.index(after: index)
                if after == text.endIndex { return index..<after }
                if text[after].isWhitespace { return index..<after }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func leadingSpaces(of line: String) -> Int {
        var count = 0
        for c in line {
            if c == " " { count += 1 } else { break }
        }
        return count
    }

    private static func isIgnorable(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private static func yamlError(_ message: String) -> NSError {
        NSError(domain: "AISymphony.YAML", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private enum BlockMode { case unknown, map, list }
}

private struct AILocalIssueDocument: Hashable {
    var block: BlockEntity
    var issue: AIIssue
}

actor AIWorkspaceManager {
    private let blocksRepository: any BlocksRepository
    private let dayRepository: any DayRepository
    private let tagsRepository: any TagsRepository

    private let rootURL: URL
    private var loopTask: Task<Void, Never>?
    private var configWatcher: FileWatcherService?
    private var workflowFileWatcher: FileWatcherService?

    private var serviceStatus: AIServiceStatus = .stopped
    private var lastAppConfig: AIAppConfig?
    private var lastWorkflow: AIWorkflowDefinition?
    private var lastIssues: [AIIssue] = []
    private var lastProjectScanAt: Date?
    private var discoveredProjects: [AIDiscoveredProject] = []
    private var detectedPi = AIDetectedPiRuntime(executablePath: nil, version: nil, authConfigured: false, statusDetail: "Not scanned.")
    private var detectedHermes = AIDetectedHermesRuntime(executablePath: nil, lastCheckedAt: nil)
    private let hermesProbeIntervalSeconds: TimeInterval = 60
    private var workspaces: [String: AIWorkspace] = [:]
    private var attempts: [AIRunAttempt] = []
    private var liveSessions: [String: AILiveSession] = [:]
    private var lastSentPrompt: [String: String] = [:]
    private var claimedIssueIDs: Set<String> = []
    private var completedIssueIDs: Set<String> = []
    private var logs: [AILogEntry] = []
    private var retryEntries: [String: AIRetryEntry] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var agentTotals = AIAgentTotals()
    private var lastPollAt: Date?
    private var attemptsByIssueID: [String: [AIRunAttempt]] = [:]
    private var liveSessionsByIssueID: [String: Set<String>] = [:]

    init(
        blocksRepository: any BlocksRepository,
        dayRepository: any DayRepository,
        tagsRepository: any TagsRepository
    ) {
        self.blocksRepository = blocksRepository
        self.dayRepository = dayRepository
        self.tagsRepository = tagsRepository

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.rootURL = appSupport.appendingPathComponent("Geo/Symphony", isDirectory: true)
    }

    deinit {
        loopTask?.cancel()
    }

    func snapshot() async -> AISnapshot {
        await reloadSnapshot(fetchIssues: false)
    }

    func startService() async -> AISnapshot {
        loopTask?.cancel()
        serviceStatus = .running
        appendLog(.info, "AI service started.")

        let startWorkflow = loadWorkflow()
        await startupTerminalCleanup(workflow: startWorkflow)
        startConfigWatcher()

        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.pollNow()
                let workflow = await self.currentWorkflow()
                let interval = max(workflow.config.polling.intervalMS, 1_000)
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                } catch {
                    return
                }
            }
        }

        return await pollNow()
    }

    func stopService() async -> AISnapshot {
        loopTask?.cancel()
        loopTask = nil
        serviceStatus = .stopped
        for session in liveSessions.values {
            markAttempt(issueID: session.issueID, status: .canceled, error: "Service stopped by operator.")
        }
        liveSessions.removeAll()
        liveSessionsByIssueID.removeAll()
        claimedIssueIDs.removeAll()
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        retryEntries.removeAll()
        configWatcher?.stop()
        configWatcher = nil
        workflowFileWatcher?.stop()
        workflowFileWatcher = nil
        appendLog(.info, "AI service stopped.")
        return await reloadSnapshot(fetchIssues: false)
    }

    func reloadWorkflow() async -> AISnapshot {
        lastWorkflow = loadWorkflow()
        appendLog(.info, "Reloaded WORKFLOW.md.")
        return await reloadSnapshot(fetchIssues: false)
    }

    func pollNow() async -> AISnapshot {
        let workflow = loadWorkflow()
        lastWorkflow = workflow
        lastPollAt = Date()
        detectStalls(workflow: workflow)
        refreshRuntimeDetection()
        refreshHermesDetection()
        if detectedPi.isAvailable {
            attempts.removeAll { $0.status == .failed && $0.error == "Run: pi /login" }
        }

        if let error = workflow.parseError ?? workflow.config.dispatchValidationError {
            serviceStatus = serviceStatus == .running ? .degraded : serviceStatus
            appendLog(.warning, error)
            return makeSnapshot(workflow: workflow)
        }

        refreshProjectDiscoveryIfNeeded(config: currentAppConfig(), force: false)

        do {
            lastIssues = try await fetchIssues(workflow: workflow)
            appendLog(.info, "Polled \(lastIssues.count) issue candidates.")
            if workspaces.isEmpty { restoreWorkspacesFromDisk(workflow: workflow) }
            await reconcileAgainstLatestIssues(workflow: workflow)
        } catch {
            serviceStatus = serviceStatus == .running ? .degraded : serviceStatus
            appendLog(.error, "Poll failed: \(error.localizedDescription)")
        }

        await ingestAgentReports()
        return makeSnapshot(workflow: workflow)
    }

    func createIssue(title: String, description: String, model: String?, effort: String?) async -> AISnapshot {
        let workflow = await currentWorkflow()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            appendLog(.warning, "Cannot create a AI issue without a title.")
            return makeSnapshot(workflow: workflow)
        }

        do {
            let existing = try await localIssueDocuments()
            let identifier = nextLocalIssueIdentifier(existing.map(\.issue))
            let now = Date()
            let markdown = localIssueMarkdown(
                identifier: identifier,
                title: trimmedTitle,
                state: "Backlog",
                description: description,
                model: model,
                effort: effort
            )
            let block = try await blocksRepository.create(title: "\(identifier) \(trimmedTitle)", markdown: markdown)
            let issue = AIIssue(
                id: identifier,
                identifier: identifier,
                title: trimmedTitle,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                priority: nil,
                state: "Backlog",
                branchName: nil,
                url: nil,
                labels: ["local"],
                blockedBy: [],
                createdAt: now,
                updatedAt: now,
                linkedBlockID: block.id
            )
            lastIssues = sortedIssues(existing.map(\.issue) + [issue])
            appendLog(.info, "Created local AI issue \(identifier) and linked Node \(block.id).")
        } catch {
            appendLog(.error, "Local issue creation failed: \(error.localizedDescription)")
        }

        return makeSnapshot(workflow: workflow)
    }

    private func writeLocalIssueState(issueID: String, state: String) async {
        do {
            try await updateLocalIssueFrontmatter(issueID: issueID, values: [
                "state": canonicalIssueState(state),
                "updated_at": ISO8601DateFormatter().string(from: Date())
            ])
            lastIssues = sortedIssues(try await localIssueDocuments().map(\.issue))
        } catch {
            appendLog(.error, "State transition failed for \(identifier(for: issueID)): \(error.localizedDescription)")
        }
    }

    func updateIssueState(issueID: String, state: String) async -> AISnapshot {
        let workflow = await currentWorkflow()
        let canonicalState = canonicalIssueState(state)
        do {
            guard try await localIssueDocument(issueID: issueID) != nil else {
                appendLog(.warning, "Cannot update missing local issue \(issueID).")
                return makeSnapshot(workflow: workflow)
            }
            try await updateLocalIssueFrontmatter(issueID: issueID, values: [
                "state": canonicalState,
                "updated_at": ISO8601DateFormatter().string(from: Date())
            ])
            lastIssues = sortedIssues(try await localIssueDocuments().map(\.issue))
            appendLog(.info, "Moved \(identifier(for: issueID)) to \(canonicalState).")
        } catch {
            appendLog(.error, "State update failed for \(identifier(for: issueID)): \(error.localizedDescription)")
        }
        let terminalStates = Set(workflow.config.tracker.terminalStates.map(normalizeState))
        let activeStates = Set(workflow.config.tracker.activeStates.map(normalizeState))
        let normalized = normalizeState(canonicalState)
        if terminalStates.contains(normalized) {
            terminateSessions(forIssueID: issueID, reason: "Issue moved to terminal state.")
            completedIssueIDs.insert(issueID)
            await clearSymphonySessionID(issueID: issueID)
        } else {
            completedIssueIDs.remove(issueID)
            if activeStates.contains(normalized), let issue = lastIssues.first(where: { $0.id == issueID }) {
                await dispatch(issue: issue, workflow: workflow, forcedProject: nil)
            }
        }
        return makeSnapshot(workflow: workflow)
    }

    func deleteIssue(issueID: String) async -> AISnapshot {
        let workflow = await currentWorkflow()
        performIssueCleanup(issueID: issueID, reason: "Issue deleted by operator.")
        do {
            let doc = try await localIssueDocument(issueID: issueID)
            let ident = doc?.issue.identifier ?? issueID
            if let blockID = doc?.block.id {
                try await blocksRepository.delete(id: blockID)
            }
            lastIssues = sortedIssues(try await localIssueDocuments().map(\.issue))
            appendLog(.info, "Deleted issue \(ident).")
        } catch {
            appendLog(.error, "Delete failed for \(issueID): \(error.localizedDescription)")
        }
        return makeSnapshot(workflow: workflow)
    }

    private func performIssueCleanup(issueID: String, reason: String) {
        terminateSessions(forIssueID: issueID, reason: reason)
        retryTasks[issueID]?.cancel()
        retryTasks.removeValue(forKey: issueID)
        retryEntries.removeValue(forKey: issueID)
        claimedIssueIDs.remove(issueID)
        completedIssueIDs.remove(issueID)
        cleanupWorkspace(issueID: issueID)
    }

    func dispatch(issueID: String) async -> AISnapshot {
        let workflow = await currentWorkflow()
        guard let issue = lastIssues.first(where: { $0.id == issueID }) else {
            appendLog(.warning, "Cannot dispatch missing issue \(issueID).")
            return makeSnapshot(workflow: workflow)
        }
        await dispatch(issue: issue, workflow: workflow, forcedProject: nil)
        return makeSnapshot(workflow: workflow)
    }

    func dispatch(
        issueID: String,
        project: AIDiscoveredProject?
    ) async -> AISnapshot {
        let workflow = await currentWorkflow()
        guard let issue = lastIssues.first(where: { $0.id == issueID }) else {
            appendLog(.warning, "Cannot dispatch missing issue \(issueID).")
            return makeSnapshot(workflow: workflow)
        }
        await dispatch(issue: issue, workflow: workflow, forcedProject: project)
        return makeSnapshot(workflow: workflow)
    }

    private func terminateSessions(forIssueID issueID: String, reason: String) {
        stopSessions(forIssueID: issueID)
        claimedIssueIDs.remove(issueID)
        markAttempt(issueID: issueID, status: .canceled, error: reason)
    }

    private func stopSessions(forIssueID issueID: String) {
        guard let sessionIDs = liveSessionsByIssueID.removeValue(forKey: issueID) else { return }
        for sessionID in sessionIDs {
            liveSessions.removeValue(forKey: sessionID)
        }
    }

    func release(issueID: String) async -> AISnapshot {
        let workflow = await currentWorkflow()
        terminateSessions(forIssueID: issueID, reason: "Released by operator.")
        retryTasks[issueID]?.cancel()
        retryTasks.removeValue(forKey: issueID)
        retryEntries.removeValue(forKey: issueID)
        completedIssueIDs.remove(issueID)
        appendLog(.info, "Released \(identifier(for: issueID)).")
        return makeSnapshot(workflow: workflow)
    }

    func openWorkflow() async {
        let url = resolveWorkflowMarkdownURL()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("WORKFLOW.md")
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }
    }

    func openIssueNode(issueID: String) async {
        guard let linkedBlockID = await ensureIssueNode(issueID: issueID),
              let block = try? await blockEntity(id: linkedBlockID) else { return }
        let url = block.url
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }
    }

    func ensureIssueNode(issueID: String) async -> String? {
        guard var issue = lastIssues.first(where: { $0.id == issueID }) else { return nil }
        if let linkedBlockID = issue.linkedBlockID,
           (try? await blockEntity(id: linkedBlockID)) != nil {
            return linkedBlockID
        }

        do {
            let markdown = localIssueMarkdown(
                identifier: issue.identifier,
                title: issue.title,
                state: issue.state,
                description: issue.description ?? ""
            )
            let block = try await blocksRepository.create(title: "\(issue.identifier) \(issue.title)", markdown: markdown)
            issue.linkedBlockID = block.id
            issue.updatedAt = Date()

            if let index = lastIssues.firstIndex(where: { $0.id == issueID }) {
                lastIssues[index] = issue
            }

            appendLog(.info, "Linked \(issue.identifier) to Node \(block.id).")
            return block.id
        } catch {
            appendLog(.error, "Node link failed for \(issue.identifier): \(error.localizedDescription)")
            return nil
        }
    }

    func openWorkspace(issueID: String) async {
        if let workspace = workspaces[issueID] {
            let url = URL(fileURLWithPath: workspace.path, isDirectory: true)
            await MainActor.run {
                _ = NSWorkspace.shared.open(url)
            }
            return
        }

        let workflow = await currentWorkflow()
        guard let issue = lastIssues.first(where: { $0.id == issueID }),
              let workspace = try? prepareWorkspace(
                for: issue,
                workflow: workflow,
                project: nil
              ) else { return }
        let url = URL(fileURLWithPath: workspace.path, isDirectory: true)
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }
    }

    private func currentWorkflow() async -> AIWorkflowDefinition {
        if let lastWorkflow { return lastWorkflow }
        let workflow = loadWorkflow()
        lastWorkflow = workflow
        return workflow
    }

    private func currentAppConfig() -> AIAppConfig {
        if let lastAppConfig { return lastAppConfig }
        let config = AIAppConfig.defaults(rootURL: rootURL)
        lastAppConfig = config
        return config
    }

    private func reloadSnapshot(fetchIssues: Bool) async -> AISnapshot {
        let workflow = loadWorkflow()
        lastWorkflow = workflow
        if fetchIssues {
            do {
                lastIssues = try await self.fetchIssues(workflow: workflow)
            } catch {
                appendLog(.warning, "Issue refresh failed: \(error.localizedDescription)")
            }
        } else if lastIssues.isEmpty {
            lastIssues = await fallbackIssues()
        }
        await ingestAgentReports()
        return makeSnapshot(workflow: workflow)
    }

    private func makeSnapshot(workflow: AIWorkflowDefinition) -> AISnapshot {
        let state = AIOrchestratorState(
            serviceStatus: serviceStatus,
            pollIntervalMS: workflow.config.polling.intervalMS,
            maxConcurrentAgents: workflow.config.agent.maxConcurrentAgents,
            runningIssueIDs: Set(liveSessions.values.map(\.issueID)),
            runningSessionIDs: Set(liveSessions.keys),
            claimedIssueIDs: claimedIssueIDs,
            retryEntries: Array(retryEntries.values),
            completedIssueIDs: completedIssueIDs,
            agentTotals: agentTotals,
            lastPollAt: lastPollAt
        )
        return AISnapshot(
            workflow: workflow,
            state: state,
            issues: sortedIssues(lastIssues),
            workspaces: workspaces.values.sorted { $0.issueIdentifier < $1.issueIdentifier },
            attempts: attempts.sorted { $0.startedAt > $1.startedAt },
            liveSessions: liveSessions.values.sorted { $0.startedAt > $1.startedAt },
            logs: logs.sorted { $0.timestamp > $1.timestamp },
            projects: discoveredProjects,
            selectedProjectID: selectProject(for: nil, config: currentAppConfig())?.id,
            agentRuntimes: publicAgentRuntimes()
        )
    }

    private func dispatchEligibleIssues(workflow: AIWorkflowDefinition) async {
        let maxAgents = max(workflow.config.agent.maxConcurrentAgents, 1)
        var availableSlots = max(maxAgents - liveSessions.count, 0)
        guard availableSlots > 0 else { return }

        let maxByState = workflow.config.agent.maxConcurrentAgentsByState
        var perStateLive: [String: Int] = [:]
        if !maxByState.isEmpty {
            for session in liveSessions.values {
                guard let issue = lastIssues.first(where: { $0.id == session.issueID }) else { continue }
                perStateLive[issue.normalizedState, default: 0] += 1
            }
        }

        for issue in sortedIssues(lastIssues) {
            guard availableSlots > 0 else { break }
            guard isEligible(issue, workflow: workflow) else { continue }
            let normalizedIssueState = normalizeState(issue.state)
            if let limit = maxByState[normalizedIssueState],
               (perStateLive[normalizedIssueState] ?? 0) >= limit {
                continue
            }
            await dispatch(issue: issue, workflow: workflow, forcedProject: nil)
            perStateLive[normalizedIssueState, default: 0] += 1
            availableSlots -= 1
        }
    }

    private func dispatch(
        issue: AIIssue,
        workflow: AIWorkflowDefinition,
        forcedProject: AIDiscoveredProject?
    ) async {
        refreshHermesDetection()
        guard detectedHermes.isAvailable else {
            var attempt = AIRunAttempt(
                id: UUID(),
                issueID: issue.id,
                issueIdentifier: issue.identifier,
                projectID: forcedProject?.id,
                projectName: forcedProject?.name,
                projectRootPath: forcedProject?.rootPath,
                agent: .hermes,
                attempt: nextAttemptNumber(for: issue.id),
                workspacePath: workspaces[issue.id]?.path ?? "",
                status: .failed,
                error: "hermes runtime is not available. Install hermes."
            )
            attempt.finishedAt = Date()
            insertAttempt(attempt, at: 0)
            appendLog(.error, "Dispatch failed for \(issue.identifier): hermes not available.")
            return
        }
        await dispatchViaHermes(issue: issue, workflow: workflow, forcedProject: forcedProject)
    }

    private func dispatchViaHermes(
        issue: AIIssue,
        workflow: AIWorkflowDefinition,
        forcedProject: AIDiscoveredProject?
    ) async {
        guard isEligible(issue, workflow: workflow) else {
            appendLog(.warning, "\(issue.identifier) is not eligible for hermes dispatch.")
            return
        }

        let preflightAttemptID = UUID()
        let preflightAttemptNumber = nextAttemptNumber(for: issue.id)
        insertAttempt(AIRunAttempt(
            id: preflightAttemptID,
            issueID: issue.id,
            issueIdentifier: issue.identifier,
            projectID: forcedProject?.id,
            projectName: forcedProject?.name,
            projectRootPath: forcedProject?.rootPath,
            agent: .hermes,
            attempt: preflightAttemptNumber,
            workspacePath: workspaces[issue.id]?.path ?? "",
            status: .preparing
        ), at: 0)
        claimedIssueIDs.insert(issue.id)

        do {
            let appConfig = currentAppConfig()
            refreshProjectDiscoveryIfNeeded(config: appConfig, force: discoveredProjects.isEmpty)

            guard let project = forcedProject ?? selectProject(for: issue, config: appConfig) else {
                throw dispatchError("No local project was discovered for \(issue.identifier). Update WORKFLOW.md project discovery settings or search roots.")
            }

            let workspace = try prepareWorkspace(for: issue, workflow: workflow, project: project)
            let attemptNumber = nextAttemptNumber(for: issue.id)
            let maxTurns = max(workflow.config.agent.maxTurns, 1)
            guard attemptNumber <= maxTurns else {
                claimedIssueIDs.remove(issue.id)
                appendLog(.warning, "Skipped hermes dispatch for \(issue.identifier): would exceed max_turns (\(maxTurns)).")
                return
            }

            let nodeMarkdown = await issueNodeMarkdown(for: issue)
            if let nextPromptText = extractNextPromptSection(from: nodeMarkdown), !nextPromptText.isEmpty {
                lastSentPrompt[issue.id] = nextPromptText
            } else {
                lastSentPrompt.removeValue(forKey: issue.id)
            }
            let promptTemplate = attemptNumber > 1
                ? continuationPromptTemplate(base: workflow.promptTemplate)
                : workflow.promptTemplate
            let renderedPrompt = try renderPrompt(
                template: promptTemplate,
                issue: issue,
                nodeMarkdown: nodeMarkdown,
                attempt: attemptNumber,
                project: project,
                agentWorkspacePath: workspace.path
            )
            try writeRunFiles(issue: issue, workspace: workspace, prompt: renderedPrompt, project: project, nodeMarkdown: nodeMarkdown)
            try runHook(
                workflow.config.hooks.beforeRun,
                cwd: URL(fileURLWithPath: workspace.path, isDirectory: true),
                timeoutMS: workflow.config.hooks.timeoutMS
            )

            let preparedAgent = try prepareAgentWorkspace(
                issue: issue,
                workflow: workflow,
                workspace: workspace,
                project: project,
                attempt: attemptNumber,
                nodeMarkdown: nodeMarkdown
            )

            if let index = attempts.firstIndex(where: { $0.id == preflightAttemptID }) {
                removeAttempt(at: index)
            }

            let agentAttemptID = UUID()
            let sessionID = "hermes-\(UUID().uuidString.prefix(8))"
            let provider = await piProvider()
            let effectiveModel: String? = {
                let pinned = issue.symphonyModel?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pinned, !pinned.isEmpty { return pinned }
                let fallback = workflow.config.pi.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let fallback, !fallback.isEmpty { return fallback }
                return defaultModel(for: provider)
            }()
            let effectiveEffort: String? = {
                let pinned = issue.symphonyEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pinned, !pinned.isEmpty { return pinned }
                let trimmed = workflow.config.pi.effort?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (trimmed?.isEmpty ?? true) ? nil : trimmed
            }()
            let resumePiSessionID = issue.symphonySessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let systemPrompt = piSystemPrompt(reportPath: reportPath(forAgentWorkspacePath: preparedAgent.rootURL.path))

            insertAttempt(AIRunAttempt(
                id: agentAttemptID,
                issueID: issue.id,
                issueIdentifier: issue.identifier,
                projectID: project.id,
                projectName: project.name,
                projectRootPath: project.rootPath,
                agent: .hermes,
                attempt: attemptNumber,
                workspacePath: preparedAgent.rootURL.path,
                status: .launching
            ), at: 0)
            registerLiveSession(AILiveSession(
                issueID: issue.id,
                issueIdentifier: issue.identifier,
                sessionID: sessionID,
                threadID: agentAttemptID.uuidString.lowercased(),
                turnID: "background",
                processID: nil,
                lastEvent: "hermes launching",
                lastTimestamp: Date(),
                lastMessage: "hermes is starting for \(project.name).",
                inputTokens: 0,
                outputTokens: 0,
                totalTokens: 0,
                turnCount: 0,
                startedAt: Date(),
                workspacePath: preparedAgent.rootURL.path,
                projectID: project.id,
                projectName: project.name,
                projectRootPath: project.rootPath,
                agent: .hermes,
                provider: provider,
                modelLabel: effectiveModel,
                piSessionID: (resumePiSessionID?.isEmpty == false) ? resumePiSessionID : nil
            ))

            if let index = attempts.firstIndex(where: { $0.id == agentAttemptID }) {
                mutateAttempt(at: index) { $0.status = .running }
            }

            var toolInput: [String: AnyCodableValue] = [
                "target": .string("local"),
                "block_id": .string(issue.id),
                "prompt": .string(preparedAgent.prompt),
                "system_prompt": .string(systemPrompt),
                "provider": .string(provider),
                "working_directory": .string(preparedAgent.workingDirectoryURL.path),
                "agent_root": .string(preparedAgent.rootURL.path)
            ]
            if let model = effectiveModel { toolInput["model"] = .string(model) }
            if let effort = effectiveEffort { toolInput["effort"] = .string(effort) }
            if let resume = resumePiSessionID, !resume.isEmpty {
                toolInput["resume_pi_session_id"] = .string(resume)
            }

            if workflow.config.tracker.kind == "local" {
                await writeLocalIssueState(issueID: issue.id, state: "In Progress")
            }
            appendLog(.info, "Dispatched \(issue.identifier) to hermes (\(provider)) for \(project.name) in \(workspace.path).")

            let capturedIssueID = issue.id
            let capturedSessionID = sessionID
            Task { [weak self] in
                await self?.runHermesToolCall(
                    sessionID: capturedSessionID,
                    issueID: capturedIssueID,
                    input: .object(toolInput),
                    workspacePath: preparedAgent.rootURL.path
                )
            }
        } catch {
            claimedIssueIDs.remove(issue.id)
            removeLiveSessions(forIssueID: issue.id)
            markAttempt(issueID: issue.id, status: .failed, error: error.localizedDescription)
            appendLog(.error, "Hermes dispatch failed for \(issue.identifier): \(error.localizedDescription)")
        }
    }

    private func runHermesToolCall(
        sessionID: String,
        issueID: String,
        input: AnyCodableValue,
        workspacePath: String
    ) async {
        _ = input
        _ = workspacePath
        let message = "kanban dispatch via hermes MCP is disabled — `mcp_hermes_dispatch_subagent` is not exposed by `hermes mcp serve`. Install hermes-extensions/dispatch-subagent or wire to direct `claude` spawn before re-enabling."
        markAttempt(issueID: issueID, status: .failed, error: message)
        appendLog(.error, "hermes dispatch unavailable for \(identifier(for: issueID)): \(message)")
        removeLiveSession(sessionID: sessionID)
        claimedIssueIDs.remove(issueID)
        if false {
            // Keeps handleHermesPartial/handleHermesResult referenced so
            // they don't become unused while the dispatch surface is offline.
            await handleHermesPartial(sessionID: sessionID, issueID: issueID, value: .null)
            await handleHermesResult(sessionID: sessionID, issueID: issueID, value: .null, workspacePath: workspacePath)
        }
    }

    private func handleHermesPartial(sessionID: String, issueID: String, value: AnyCodableValue) async {
        guard case .object(let obj) = value else { return }
        let eventType: String? = {
            if case .string(let s)? = obj["type"] { return s }
            if case .string(let s)? = obj["event"] { return s }
            return nil
        }()
        if eventType == "session" || eventType == "pi_session" {
            let id: String? = {
                if case .string(let s)? = obj["pi_session_id"] { return s }
                return nil
            }()
            if let id, !id.isEmpty {
                if var session = liveSessions[sessionID], session.piSessionID != id {
                    session.piSessionID = id
                    session.lastTimestamp = Date()
                    liveSessions[sessionID] = session
                }
                await stampSymphonySessionID(issueID: issueID, sessionID: id)
            }
            return
        }
        if var session = liveSessions[sessionID] {
            if let eventType { session.lastEvent = eventType }
            if case .string(let msg)? = obj["message"] {
                session.lastMessage = String(msg.suffix(160))
            }
            session.lastTimestamp = Date()
            liveSessions[sessionID] = session
        }
    }

    private func handleHermesResult(
        sessionID: String,
        issueID: String,
        value: AnyCodableValue,
        workspacePath: String
    ) async {
        var status: AIRunStatus = .succeeded
        var errorMessage: String?
        var noResult = false
        switch value {
        case .object(let obj):
            if case .string(let s)? = obj["status"] {
                switch s.lowercased() {
                case "failed", "error": status = .failed
                case "canceled", "cancelled": status = .canceled
                default: status = .succeeded
                }
            }
            if case .string(let s)? = obj["error"] { errorMessage = s }
            if case .string(let id)? = obj["pi_session_id"], !id.isEmpty {
                if var session = liveSessions[sessionID], session.piSessionID != id {
                    session.piSessionID = id
                    liveSessions[sessionID] = session
                }
                await stampSymphonySessionID(issueID: issueID, sessionID: id)
            }
        case .null:
            status = .failed
            errorMessage = "hermes returned no result — child likely crashed or hermes not installed correctly."
            noResult = true
            appendLog(.error, "hermes returned no result for \(identifier(for: issueID)); marking failed and skipping retry.")
        default:
            status = .failed
            errorMessage = "hermes returned an unexpected result shape."
            noResult = true
            appendLog(.error, "hermes returned unexpected result for \(identifier(for: issueID)); marking failed and skipping retry.")
        }

        let workflow = await currentWorkflow()
        do {
            try runHook(
                workflow.config.hooks.afterRun,
                cwd: URL(fileURLWithPath: workspacePath, isDirectory: true),
                timeoutMS: workflow.config.hooks.timeoutMS
            )
        } catch {
            appendLog(.warning, "after_run failed for \(identifier(for: issueID)): \(error.localizedDescription)")
        }

        await ingestAgentReports()
        removeLiveSession(sessionID: sessionID)
        claimedIssueIDs.remove(issueID)
        markAttempt(issueID: issueID, status: status, error: errorMessage)

        if status == .succeeded {
            let activeStates = Set(workflow.config.tracker.activeStates.map(normalizeState))
            let terminalStates = Set(workflow.config.tracker.terminalStates.map(normalizeState))
            let refreshed = try? await fetchIssueStatesByIDs([issueID], workflow: workflow).first
            let normalizedState = refreshed.map { normalizeState($0.state) }
            let stillActive = normalizedState.map { activeStates.contains($0) } ?? false
            if let normalizedState, terminalStates.contains(normalizedState) {
                completedIssueIDs.insert(issueID)
                cleanupWorkspace(issueID: issueID)
                appendLog(.info, "hermes finished \(identifier(for: issueID)); tracker state is terminal.")
                return
            }
            let attemptCount = attemptsByIssueID[issueID]?.count ?? 0
            let maxTurns = max(workflow.config.agent.maxTurns, 1)
            if stillActive && attemptCount < maxTurns {
                appendLog(.info, "hermes finished turn \(attemptCount) for \(identifier(for: issueID)); scheduling continuation.")
                Task { [weak self] in
                    guard let wf = await self?.currentWorkflow() else { return }
                    await self?.scheduleRetry(issueID: issueID, workflow: wf, abnormal: false)
                }
                return
            }
        } else if !noResult {
            Task { [weak self] in
                guard let wf = await self?.currentWorkflow() else { return }
                await self?.scheduleRetry(issueID: issueID, workflow: wf, abnormal: true)
            }
        }
    }

    private func hermesServerSpec() -> MCPServerSpec {
        let command = ProcessInfo.processInfo.environment["HERMES_MCP_COMMAND"] ?? "hermes"
        let argsRaw = ProcessInfo.processInfo.environment["HERMES_MCP_ARGS"] ?? "mcp"
        let arguments = argsRaw.split(separator: " ").map(String.init)
        return MCPServerSpec(name: "hermes", command: command, arguments: arguments, environment: backgroundAgentEnvironment())
    }

    private func isEligible(_ issue: AIIssue, workflow: AIWorkflowDefinition) -> Bool {
        let activeStates = Set(workflow.config.tracker.activeStates.map(normalizeState))
        let terminalStates = Set(workflow.config.tracker.terminalStates.map(normalizeState))
        guard activeStates.contains(issue.normalizedState), !terminalStates.contains(issue.normalizedState) else { return false }
        let isRunning = liveSessions.values.contains { $0.issueID == issue.id }
        guard !claimedIssueIDs.contains(issue.id), !isRunning, !completedIssueIDs.contains(issue.id) else { return false }

        if issue.normalizedState == "todo" {
            let blocked = issue.blockedBy.contains { blocker in
                guard let blockerState = blocker.state else { return true }
                return !terminalStates.contains(normalizeState(blockerState))
            }
            if blocked { return false }
        }

        return true
    }

    private func reconcileAgainstLatestIssues(workflow: AIWorkflowDefinition) async {
        let activeStates = Set(workflow.config.tracker.activeStates.map(normalizeState))
        let terminalStates = Set(workflow.config.tracker.terminalStates.map(normalizeState))
        let runningIssueIDs = Array(Set(liveSessions.values.map(\.issueID)))
        guard !runningIssueIDs.isEmpty else { return }

        let refreshedIssues: [AIIssue]
        do {
            refreshedIssues = try await fetchIssueStatesByIDs(runningIssueIDs, workflow: workflow)
        } catch {
            appendLog(.warning, "Running issue state refresh failed: \(error.localizedDescription)")
            return
        }
        let issueByID = Dictionary(uniqueKeysWithValues: refreshedIssues.map { ($0.id, $0) })

        for issueID in runningIssueIDs {
            guard let issue = issueByID[issueID] else { continue }
            let state = normalizeState(issue.state)
            if terminalStates.contains(state) {
                stopSessions(forIssueID: issueID)
                claimedIssueIDs.remove(issueID)
                retryTasks[issueID]?.cancel()
                retryTasks.removeValue(forKey: issueID)
                retryEntries.removeValue(forKey: issueID)
                completedIssueIDs.insert(issueID)
                markAttempt(issueID: issueID, status: .succeeded, error: nil)
                cleanupWorkspace(issueID: issueID)
            } else if !activeStates.contains(state) {
                stopSessions(forIssueID: issueID)
                claimedIssueIDs.remove(issueID)
                retryTasks[issueID]?.cancel()
                retryTasks.removeValue(forKey: issueID)
                retryEntries.removeValue(forKey: issueID)
                markAttempt(issueID: issueID, status: .canceled, error: "Issue left active states.")
            }
        }
    }

    private func prepareWorkspace(
        for issue: AIIssue,
        workflow: AIWorkflowDefinition,
        project: AIDiscoveredProject?
    ) throws -> AIWorkspace {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: workflow.config.workspace.root, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let key = sanitizeWorkspaceKey(issue.identifier)
        let workspaceURL = root.appendingPathComponent(key, isDirectory: true)
        try validateWorkspaceContainment(root: root, workspace: workspaceURL)
        let existed = fm.fileExists(atPath: workspaceURL.path)
        if !existed {
            try fm.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        }

        if !existed {
            try runHook(workflow.config.hooks.afterCreate, cwd: workspaceURL, timeoutMS: workflow.config.hooks.timeoutMS)
        }

        let now = Date()
        let workspace = AIWorkspace(
            issueID: issue.id,
            issueIdentifier: issue.identifier,
            workspaceKey: key,
            path: workspaceURL.path,
            createdAt: workspaces[issue.id]?.createdAt ?? now,
            lastPreparedAt: now,
            projectID: project?.id,
            projectName: project?.name,
            projectRootPath: project?.rootPath,
            agent: .pi
        )
        workspaces[issue.id] = workspace
        persistWorkspaceManifest(workspace, workflow: workflow)
        return workspace
    }

    private func persistWorkspaceManifest(
        _ workspace: AIWorkspace,
        workflow: AIWorkflowDefinition
    ) {
        let metaURL = URL(fileURLWithPath: workspace.path, isDirectory: true)
            .appendingPathComponent(".symphony", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: metaURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(workspace)
            try data.write(to: metaURL.appendingPathComponent("workspace.json"), options: .atomic)
        } catch {
            appendLog(.warning, "Failed to persist workspace manifest for \(workspace.issueIdentifier): \(error.localizedDescription)")
        }
    }

    private func writeRunFiles(
        issue: AIIssue,
        workspace: AIWorkspace,
        prompt: String,
        project: AIDiscoveredProject,
        nodeMarkdown: String
    ) throws {
        let fm = FileManager.default
        let workspaceURL = URL(fileURLWithPath: workspace.path, isDirectory: true)
        let metaURL = workspaceURL.appendingPathComponent(".symphony", isDirectory: true)
        try fm.createDirectory(at: metaURL, withIntermediateDirectories: true)

        try? fm.removeItem(at: metaURL.appendingPathComponent("report.md"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(issue).write(to: metaURL.appendingPathComponent("issue.json"), options: .atomic)
        try encoder.encode(project).write(to: metaURL.appendingPathComponent("project.json"), options: .atomic)
        try prompt.write(to: metaURL.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
        try nodeMarkdown.write(to: metaURL.appendingPathComponent("node.md"), atomically: true, encoding: .utf8)

        let run = AIProjectRunMetadata(
            issueID: issue.id,
            issueIdentifier: issue.identifier,
            agent: nil,
            project: project,
            workspacePath: workspace.path,
            workingDirectoryPath: workspace.path,
            createdAt: Date()
        )
        try encoder.encode(run).write(to: metaURL.appendingPathComponent("run.json"), options: .atomic)
    }

    private func restoreWorkspacesFromDisk(workflow: AIWorkflowDefinition) {
        let root = URL(fileURLWithPath: workflow.config.workspace.root, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let now = Date()
        var restored = 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for dir in contents {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let key = dir.lastPathComponent
            guard let issue = lastIssues.first(where: { sanitizeWorkspaceKey($0.identifier) == key }) else { continue }
            guard workspaces[issue.id] == nil else { continue }
            let manifestURL = dir.appendingPathComponent(".symphony/workspace.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? decoder.decode(AIWorkspace.self, from: data) {
                workspaces[issue.id] = manifest
                restored += 1
                continue
            }
            let createdAt = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            workspaces[issue.id] = AIWorkspace(
                issueID: issue.id,
                issueIdentifier: issue.identifier,
                workspaceKey: key,
                path: dir.path,
                createdAt: createdAt,
                lastPreparedAt: now,
                projectID: nil,
                projectName: nil,
                projectRootPath: nil,
                agent: .pi
            )
            restored += 1
        }
        if restored > 0 {
            appendLog(.info, "Restored \(restored) workspace(s) from disk.")
        }
    }

    private func cleanupWorkspace(issueID: String) {
        guard let workspace = workspaces[issueID] else { return }
        let workflow = lastWorkflow ?? loadWorkflow()
        let workspaceURL = URL(fileURLWithPath: workspace.path, isDirectory: true)
        do {
            try runHook(workflow.config.hooks.beforeRemove, cwd: workspaceURL, timeoutMS: workflow.config.hooks.timeoutMS)
        } catch {
            appendLog(.warning, "before_remove failed for \(workspace.issueIdentifier): \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: workspaceURL)
        workspaces.removeValue(forKey: issueID)
    }

    private func localIssues() async -> [AIIssue] {
        do {
            return try await localIssueDocuments().map(\.issue)
        } catch {
            appendLog(.error, "Local issue load failed: \(error.localizedDescription)")
            return []
        }
    }

    private func localIssueDocuments() async throws -> [AILocalIssueDocument] {
        try await blocksRepository.list().compactMap(parseLocalIssueDocument)
    }

    private func localIssueDocument(issueID: String) async throws -> AILocalIssueDocument? {
        try await localIssueDocuments().first { $0.issue.id == issueID || $0.issue.identifier == issueID || $0.block.id == issueID }
    }

    private func parseLocalIssueDocument(_ block: BlockEntity) -> AILocalIssueDocument? {
        guard let parts = markdownFrontmatter(block.markdown),
              boolValue(parts.frontmatter["symphony"]) == true else { return nil }
        let identifier = stringValue(parts.frontmatter["identifier"])
            ?? stringValue(parts.frontmatter["symphony_id"])
            ?? block.displayTitle.components(separatedBy: " ").first
        guard let identifier, !identifier.isEmpty else { return nil }
        let id = stringValue(parts.frontmatter["id"]) ?? identifier
        let state = stringValue(parts.frontmatter["state"])
            ?? stringValue(parts.frontmatter["symphony_state"])
            ?? block.metadata.status
            ?? "Todo"
        let title = stringValue(parts.frontmatter["title"])
            ?? headingTitle(from: parts.body, identifier: identifier)
            ?? block.displayTitle
        let description = stringValue(parts.frontmatter["description"]) ?? brief(from: parts.body)
        let labels = stringArray(parts.frontmatter["labels"]).map { $0.lowercased() }
        let blockers = stringArray(parts.frontmatter["blocked_by"]).map {
            AIBlocker(trackerID: nil, identifier: $0, state: nil, createdAt: nil, updatedAt: nil)
        }
        let issue = AIIssue(
            id: id,
            identifier: identifier,
            title: title,
            description: description,
            priority: intValue(parts.frontmatter["priority"]),
            state: state,
            branchName: stringValue(parts.frontmatter["branch_name"]),
            url: stringValue(parts.frontmatter["url"]) ?? block.url.absoluteString,
            labels: labels.isEmpty ? ["local"] : labels,
            blockedBy: blockers,
            createdAt: dateValue(parts.frontmatter["created_at"]) ?? block.date,
            updatedAt: dateValue(parts.frontmatter["updated_at"]) ?? block.lastEdited,
            linkedBlockID: block.id,
            symphonyAgent: stringValue(parts.frontmatter["symphony_agent"]),
            symphonyModel: stringValue(parts.frontmatter["symphony_model"]),
            symphonyEffort: stringValue(parts.frontmatter["symphony_effort"]),
            symphonySessionID: stringValue(parts.frontmatter["symphony_session_id"])
        )
        return AILocalIssueDocument(block: block, issue: issue)
    }

    private func blockEntity(id: String) async throws -> BlockEntity? {
        try await blocksRepository.list().first { $0.id == id }
    }

    private func issueNodeMarkdown(for issue: AIIssue) async -> String {
        guard let linkedBlockID = issue.linkedBlockID,
              let block = try? await blockEntity(id: linkedBlockID) else {
            return issue.description ?? ""
        }
        return block.markdown
    }

    private func ingestAgentReports() async {
        let unfinishedAttempts = attempts.filter { $0.finishedAt == nil && $0.status == .running }
        guard !unfinishedAttempts.isEmpty else { return }

        for attempt in unfinishedAttempts {
            let reportURL = URL(fileURLWithPath: attempt.workspacePath, isDirectory: true)
                .appendingPathComponent(".symphony", isDirectory: true)
                .appendingPathComponent("report.md")
            guard FileManager.default.fileExists(atPath: reportURL.path),
                  let report = try? String(contentsOf: reportURL, encoding: .utf8),
                  !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            markAttempt(issueID: attempt.issueID, status: .succeeded, error: nil)
            if let sessionIDs = liveSessionsByIssueID[attempt.issueID] {
                for sessionID in sessionIDs where liveSessions[sessionID]?.agent == attempt.agent {
                    removeLiveSession(sessionID: sessionID)
                }
            }
            claimedIssueIDs.remove(attempt.issueID)
            await moveLocalIssueToHumanReview(issueID: attempt.issueID, report: report)
            appendLog(.info, "Ingested pi report for \(attempt.issueIdentifier).")
        }
    }

    private func moveLocalIssueToHumanReview(issueID: String, report: String) async {
        do {
            guard let doc = try await localIssueDocument(issueID: issueID) else { return }
            let updatedIssue = AIIssue(
                id: doc.issue.id,
                identifier: doc.issue.identifier,
                title: doc.issue.title,
                description: doc.issue.description,
                priority: doc.issue.priority,
                state: "Human Review",
                branchName: doc.issue.branchName,
                url: doc.issue.url,
                labels: doc.issue.labels,
                blockedBy: doc.issue.blockedBy,
                createdAt: doc.issue.createdAt,
                updatedAt: Date(),
                linkedBlockID: doc.issue.linkedBlockID
            )
            try await appendReportToIssueNode(issue: updatedIssue, report: report)
            lastIssues = sortedIssues(try await localIssueDocuments().map(\.issue))
        } catch {
            appendLog(.error, "Report ingest failed for \(identifier(for: issueID)): \(error.localizedDescription)")
        }
    }

    private func appendReportToIssueNode(issue: AIIssue, report: String) async throws {
        guard let linkedBlockID = issue.linkedBlockID,
              try await blockEntity(id: linkedBlockID) != nil else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        _ = try await blocksRepository.mutateFrontmatter(blockId: linkedBlockID, merge: [
            "state": .string(issue.state),
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
            "symphony": .bool(true)
        ])
        guard let refreshed = try await blockEntity(id: linkedBlockID) else { return }
        var markdown = removeEmptyAgentReportPlaceholder(from: removeVisibleAIMetadata(from: refreshed.markdown))
        let trimmedReport = stripLeadingH1(from: report.trimmingCharacters(in: .whitespacesAndNewlines))
        let (progressBlock, remainingReport) = extractProgressBlock(from: trimmedReport)
        if let progressBlock {
            markdown = replaceOrInsertSection(in: markdown, heading: "## Progress", content: progressBlock)
        }
        let cleanedReport = demoteH2InsideReport(remainingReport)
        let promptQuote = consumePromptQuote(for: issue.id)
        let body = promptQuote.isEmpty ? cleanedReport : "\(promptQuote)\n\n\(cleanedReport)"
        markdown += "\n\n## Agent Report - pi - \(timestamp)\n\(body)"
        try await blocksRepository.update(id: linkedBlockID, markdown: markdown)
    }

    private func extractProgressBlock(from report: String) -> (progress: String?, remaining: String) {
        let lines = report.components(separatedBy: "\n")
        guard let startIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "## progress"
        }) else {
            return (nil, report)
        }
        var endIdx = startIdx + 1
        while endIdx < lines.count {
            let trimmed = lines[endIdx].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || (trimmed.hasPrefix("# ") && !trimmed.hasPrefix("## ")) { break }
            endIdx += 1
        }
        let progressContent = Array(lines[(startIdx + 1)..<endIdx])
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var remainingLines = lines
        remainingLines.removeSubrange(startIdx..<endIdx)
        let remaining = remainingLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (progressContent.isEmpty ? nil : progressContent, remaining)
    }

    private func replaceOrInsertSection(in markdown: String, heading: String, content: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        if let startIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == heading.lowercased()
        }) {
            var endIdx = startIdx + 1
            while endIdx < lines.count {
                let l = lines[endIdx].trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("## ") || (l.hasPrefix("# ") && !l.hasPrefix("## ")) { break }
                endIdx += 1
            }
            var out = lines
            out.replaceSubrange(startIdx..<endIdx, with: [heading, content, ""])
            return out.joined(separator: "\n")
        }
        let insertIdx: Int
        if let acceptIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("## acceptance")
        }) {
            var endIdx = acceptIdx + 1
            while endIdx < lines.count {
                let l = lines[endIdx].trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("## ") || (l.hasPrefix("# ") && !l.hasPrefix("## ")) { break }
                endIdx += 1
            }
            insertIdx = endIdx
        } else {
            insertIdx = lines.count
        }
        var out = lines
        out.insert(contentsOf: ["", heading, content], at: insertIdx)
        return out.joined(separator: "\n")
    }

    private func demoteH2InsideReport(_ body: String) -> String {
        body.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("## ") && !line.hasPrefix("### ") {
                return "###" + String(line.dropFirst(2))
            }
            return line
        }.joined(separator: "\n")
    }

    private func consumePromptQuote(for issueID: String) -> String {
        guard let raw = lastSentPrompt.removeValue(forKey: issueID) else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let quoted = trimmed
            .components(separatedBy: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "> Prompt:\n\(quoted)"
    }

    private func extractNextPromptSection(from markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        var collecting = false
        var collected: [String] = []
        for line in lines {
            if line.hasPrefix("## ") {
                if collecting { break }
                if line.trimmingCharacters(in: .whitespaces) == "## Next Prompt" {
                    collecting = true
                }
                continue
            }
            if line.hasPrefix("# ") && collecting { break }
            if collecting { collected.append(line) }
        }
        let text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func relabelNextPromptHeading(in markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { line -> String in
            line.trimmingCharacters(in: .whitespaces) == "## Next Prompt" ? "## User Request" : line
        }.joined(separator: "\n")
    }

    private func stripLeadingH1(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("# ") {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n")
    }

    private func markdownFrontmatter(_ markdown: String) -> (frontmatter: [String: Any], body: String)? {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
        var closeIndex: Int?
        var cursor = 1
        while cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                closeIndex = cursor
                break
            }
            cursor += 1
        }
        guard let closeIndex else { return nil }
        let yaml = Array(lines[1..<closeIndex]).joined(separator: "\n")
        let body = Array(lines.dropFirst(closeIndex + 1)).joined(separator: "\n")
        let frontmatter = (try? AISimpleYAMLParser.parse(yaml)) ?? [:]
        return (frontmatter, body)
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let text = stringValue(value)?.lowercased() {
            if ["true", "yes", "1"].contains(text) { return true }
            if ["false", "no", "0"].contains(text) { return false }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? Int { return "\(value)" }
        if let value = value as? Double { return "\(value)" }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let text = stringValue(value) { return Int(text) }
        return nil
    }

    private func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [Any] {
            return array.compactMap(stringValue)
        }
        if let text = stringValue(value) {
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return []
    }

    private func dateValue(_ value: Any?) -> Date? {
        guard let text = stringValue(value) else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private func headingTitle(from body: String, identifier: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("# ") else { continue }
            var title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if title.hasPrefix(identifier) {
                title = String(title.dropFirst(identifier.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return title.isEmpty ? nil : title
        }
        return nil
    }

    private func brief(from body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "## brief" }) else { return nil }
        var collected: [String] = []
        var cursor = index + 1
        while cursor < lines.count {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## ") { break }
            collected.append(line)
            cursor += 1
        }
        let text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "Write the task brief here." else { return nil }
        return text
    }

    private func nextLocalIssueIdentifier(_ issues: [AIIssue]) -> String {
        let maxNumber = issues.compactMap { issue -> Int? in
            let parts = issue.identifier.split(separator: "-")
            guard parts.count == 2, parts[0].uppercased() == "GEO" else { return nil }
            return Int(parts[1])
        }.max() ?? 0
        return String(format: "GEO-%03d", maxNumber + 1)
    }

    private func localIssueMarkdown(identifier: String, title: String, state: String, description: String, model: String? = nil, effort: String? = nil) -> String {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let modelValue = (model?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? ""
        let effortValue = (effort?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? ""
        return """
        ---
        symphony: true
        identifier: \(identifier)
        title: \(title)
        state: \(state)
        labels: [local]
        symphony_model: \(modelValue)
        symphony_effort: \(effortValue)
        symphony_session_id:
        created_at: \(timestamp)
        updated_at: \(timestamp)
        ---
        # \(identifier) \(title)

        ## Brief
        \(trimmedDescription.isEmpty ? "Write the task brief here." : trimmedDescription)

        ## Acceptance Criteria
        - [ ] Define expected behavior
        - [ ] Validate the change

        ## Next Prompt


        ## Agent Report
        No agent report yet.
        """
    }

    private func removeVisibleAIMetadata(from markdown: String) -> String {
        markdown
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed != "[[Symphony]] #symphony" else { return false }
                guard !trimmed.hasPrefix("State:") else { return false }
                return true
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    private func removeEmptyAgentReportPlaceholder(from markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\n## Agent Report\nNo agent report yet.\n", with: "\n")
            .replacingOccurrences(of: "\n## Agent Report\nNo agent report yet.", with: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    private func updateLocalIssueFrontmatter(issueID: String, values: [String: String]) async throws {
        guard let doc = try await localIssueDocument(issueID: issueID) else { return }
        var merge: [String: AnyCodableValue] = [:]
        for (key, value) in values {
            merge[key] = .string(value)
        }
        let parsedFM = MarkdownConverter.shared.parse(doc.block.markdown).frontmatter
        if parsedFM["symphony"] == nil {
            merge["symphony"] = .bool(true)
        }
        _ = try await blocksRepository.mutateFrontmatter(blockId: doc.block.id, merge: merge)
    }

    private func stampSymphonySessionID(issueID: String, sessionID: String) async {
        do {
            try await updateLocalIssueFrontmatter(issueID: issueID, values: ["symphony_session_id": sessionID])
            lastIssues = sortedIssues(try await localIssueDocuments().map(\.issue))
        } catch {
            appendLog(.warning, "Could not stamp session id for \(identifier(for: issueID)): \(error.localizedDescription)")
        }
    }

    private func clearSymphonySessionID(issueID: String) async {
        do {
            try await updateLocalIssueFrontmatter(issueID: issueID, values: ["symphony_session_id": ""])
            lastIssues = sortedIssues(try await localIssueDocuments().map(\.issue))
        } catch {
            appendLog(.warning, "Could not clear session id for \(identifier(for: issueID)): \(error.localizedDescription)")
        }
    }

    func setIssueModel(issueID: String, model: String?) async -> AISnapshot {
        await writeSymphonyFrontmatterKey(issueID: issueID, key: "symphony_model", value: model)
    }

    func setIssueEffort(issueID: String, effort: String?) async -> AISnapshot {
        await writeSymphonyFrontmatterKey(issueID: issueID, key: "symphony_effort", value: effort)
    }

    func setIssuePriority(issueID: String, priority: Int?) async -> AISnapshot {
        await writeSymphonyFrontmatterKey(issueID: issueID, key: "priority", value: priority.map(String.init))
    }

    private func writeSymphonyFrontmatterKey(issueID: String, key: String, value: String?) async -> AISnapshot {
        let workflow = await currentWorkflow()
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await updateLocalIssueFrontmatter(issueID: issueID, values: [key: trimmed])
            lastIssues = sortedIssues(try await localIssueDocuments().map(\.issue))
        } catch {
            appendLog(.error, "Could not update \(key) for \(identifier(for: issueID)): \(error.localizedDescription)")
        }
        return makeSnapshot(workflow: workflow)
    }

    private func canonicalIssueState(_ state: String) -> String {
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

    private func runHook(_ hook: String?, cwd: URL, timeoutMS: Int) throws {
        guard let hook = hook?.trimmingCharacters(in: .whitespacesAndNewlines), !hook.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", hook]
        process.currentDirectoryURL = cwd
        try process.run()
        let deadline = DispatchTime.now() + .milliseconds(max(timeoutMS, 1))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
            if process.isRunning {
                process.terminate()
            }
        }
        process.waitUntilExit()
        guard process.terminationReason != .uncaughtSignal else {
            throw NSError(
                domain: "AIHook",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Hook timed out after \(timeoutMS)ms."]
            )
        }
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AIHook",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Hook exited with status \(process.terminationStatus)."]
            )
        }
    }

    private func validateWorkspaceContainment(root: URL, workspace: URL) throws {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let normalizedWorkspace = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let rootWithSlash = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        guard normalizedWorkspace == normalizedRoot || normalizedWorkspace.hasPrefix(rootWithSlash) else {
            throw dispatchError("Workspace path escaped root: \(normalizedWorkspace)")
        }
    }

    private func piProvider() async -> String {
        let nano = await MainActor.run { NanoProvider(rawValue: UserDefaults.standard.string(forKey: NanoProviderStore.defaultsKey) ?? "") ?? .claude }
        switch nano {
        case .claude: return "anthropic"
        case .codex: return "openai-codex"
        }
    }

    private func defaultModel(for provider: String) -> String? {
        switch provider {
        case "anthropic": return "claude-opus-4-7"
        case "openai-codex": return "gpt-5.5"
        default: return nil
        }
    }

    private func combinedModelArgument(model: String?, effort: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        guard let effort = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !effort.isEmpty else {
            return model
        }
        return "\(model):\(effort)"
    }

    private func piSystemPrompt(reportPath: String) -> String {
        """
        You are pi running inside Geo as a background coding agent. When done, overwrite the Markdown report at:
        \(reportPath)
        First section MUST be `## Progress` (a checklist of concrete steps you took). Then summary, files changed, validation, risks, and `## Next Recommended State` whose body's first word is one of: Backlog, Todo, In Progress, Human Review, Rework, Merging, Done, Canceled.
        """
    }

    private func backgroundAgentEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CI"] = environment["CI"] ?? "1"
        environment["TERM"] = environment["TERM"] ?? "dumb"
        environment["NO_COLOR"] = environment["NO_COLOR"] ?? "1"
        return environment
    }

    private func prepareAgentWorkspace(
        issue: AIIssue,
        workflow: AIWorkflowDefinition,
        workspace: AIWorkspace,
        project: AIDiscoveredProject,
        attempt: Int,
        nodeMarkdown: String
    ) throws -> AIPreparedAgentWorkspace {
        let workspaceURL = URL(fileURLWithPath: workspace.path, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let prompt = try renderPrompt(
            template: workflow.promptTemplate,
            issue: issue,
            nodeMarkdown: nodeMarkdown,
            attempt: attempt,
            project: project,
            agentWorkspacePath: workspaceURL.path
        )

        let metadataURL = workspaceURL.appendingPathComponent(".symphony", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        try prompt.write(to: metadataURL.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)

        return AIPreparedAgentWorkspace(
            kind: .pi,
            rootURL: workspaceURL,
            workingDirectoryURL: workspaceURL,
            prompt: prompt
        )
    }

    private func refreshProjectDiscoveryIfNeeded(config: AIAppConfig, force: Bool) {
        let now = Date()
        if !force,
           let lastProjectScanAt,
           now.timeIntervalSince(lastProjectScanAt) * 1000 < Double(config.projectDiscovery.rescanIntervalMS) {
            return
        }
        discoveredProjects = discoverProjects(config: config)
        lastProjectScanAt = now
        appendLog(.info, "Discovered \(discoveredProjects.count) local projects.")
    }

    private func discoverProjects(config: AIAppConfig) -> [AIDiscoveredProject] {
        var results: [AIDiscoveredProject] = []
        var seen = Set<String>()
        for root in config.projectDiscovery.roots.map(expandedPath) {
            let url = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            scanProjectDirectory(
                url,
                depth: 0,
                maxDepth: config.projectDiscovery.maxDepth,
                maxEntries: config.projectDiscovery.maxEntriesPerDirectory,
                seen: &seen,
                results: &results
            )
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scanProjectDirectory(
        _ url: URL,
        depth: Int,
        maxDepth: Int,
        maxEntries: Int,
        seen: inout Set<String>,
        results: inout [AIDiscoveredProject]
    ) {
        guard depth <= maxDepth else { return }
        let path = url.standardizedFileURL.path
        guard seen.insert(path).inserted else { return }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return }

        let limitedChildren = Array(children.prefix(maxEntries))
        let markers = projectMarkers(children: limitedChildren)
        if !markers.isEmpty {
            results.append(makeProject(url: url, markers: markers))
        }

        for child in limitedChildren where shouldDescend(into: child) {
            scanProjectDirectory(
                child,
                depth: depth + 1,
                maxDepth: maxDepth,
                maxEntries: maxEntries,
                seen: &seen,
                results: &results
            )
        }
    }

    private func makeProject(url: URL, markers: [String]) -> AIDiscoveredProject {
        let rootPath = url.standardizedFileURL.path
        let gitRoot = gitRootPath(for: rootPath)
        let remote = gitRoot.flatMap { runCommand("/usr/bin/git", ["-C", $0, "remote", "get-url", "origin"]) }
        let branch = gitRoot.flatMap { runCommand("/usr/bin/git", ["-C", $0, "branch", "--show-current"]) }
        let commands = inferredCommands(markers: markers)

        return AIDiscoveredProject(
            id: rootPath,
            name: url.lastPathComponent,
            rootPath: rootPath,
            gitRootPath: gitRoot,
            gitRemote: remote,
            currentBranch: branch,
            primaryLanguage: primaryLanguage(markers: markers),
            markerSummary: markers.joined(separator: ", "),
            buildCommand: commands.build,
            testCommand: commands.test,
            trustedForAutomation: true,
            enabledAgents: AIAgentKind.allCases,
            lastScannedAt: Date()
        )
    }

    private func projectMarkers(children: [URL]) -> [String] {
        let names = Set(children.map(\.lastPathComponent))
        var markers: [String] = []
        if names.contains(".git") { markers.append(".git") }
        markers.append(contentsOf: children
            .filter { $0.pathExtension == "xcodeproj" || $0.pathExtension == "xcworkspace" }
            .map(\.lastPathComponent)
            .sorted())
        for marker in ["Package.swift", "package.json", "pnpm-lock.yaml", "yarn.lock", "pyproject.toml", "requirements.txt", "Cargo.toml", "go.mod", "mix.exs", "Gemfile", "pom.xml", "build.gradle", "settings.gradle"] {
            if names.contains(marker) { markers.append(marker) }
        }
        return markers
    }

    private func shouldDescend(into url: URL) -> Bool {
        let name = url.lastPathComponent
        guard ![".git", "node_modules", "build", "DerivedData", ".swiftpm", ".venv", "vendor", "Pods", ".Trash"].contains(name) else {
            return false
        }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return false
        }
        return values.isHidden != true
    }

    private func refreshRuntimeDetection() {
        let path = shellCommand("command -v \(shellQuote("pi"))")
        let version = path.flatMap { shellCommand("\(shellQuote($0)) --version") }
        let env = ProcessInfo.processInfo.environment
        let hasEnvKey = (env["ANTHROPIC_API_KEY"]?.isEmpty == false) || (env["OPENAI_API_KEY"]?.isEmpty == false)
        let authPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/auth.json").path
        let authSize = (try? FileManager.default.attributesOfItem(atPath: authPath)[.size] as? Int) ?? 0
        let authConfigured = authSize > 4
        let detail: String
        if path == nil {
            detail = "pi not found on PATH. brew install earendil/pi-coding-agent/pi."
        } else if !authConfigured && !hasEnvKey {
            detail = "Run: pi /login"
        } else {
            detail = "Available at \(path ?? "")."
        }
        detectedPi = AIDetectedPiRuntime(
            executablePath: path,
            version: version,
            authConfigured: authConfigured || hasEnvKey,
            statusDetail: detail
        )
    }

    private func refreshHermesDetection(force: Bool = false) {
        if !force,
           let lastCheckedAt = detectedHermes.lastCheckedAt,
           Date().timeIntervalSince(lastCheckedAt) < hermesProbeIntervalSeconds {
            return
        }
        let envCommand = ProcessInfo.processInfo.environment["HERMES_MCP_COMMAND"] ?? "hermes"
        let path = shellCommand("command -v \(shellQuote(envCommand))")
        detectedHermes = AIDetectedHermesRuntime(
            executablePath: path,
            lastCheckedAt: Date()
        )
    }

    func isHermesAvailable() -> Bool {
        refreshHermesDetection()
        return detectedHermes.isAvailable
    }

    private func publicAgentRuntimes() -> [AIAgentRuntime] {
        [AIAgentRuntime(
            kind: .pi,
            executablePath: detectedPi.executablePath,
            version: detectedPi.version,
            isAvailable: detectedPi.isAvailable,
            statusDetail: detectedPi.statusDetail
        )]
    }

    private func selectProject(for issue: AIIssue?, config: AIAppConfig) -> AIDiscoveredProject? {
        if discoveredProjects.isEmpty {
            refreshProjectDiscoveryIfNeeded(config: config, force: true)
        }
        if let selectedPath = config.projectDiscovery.selectedPath.map(expandedPath),
           let selected = discoveredProjects.first(where: { $0.rootPath == selectedPath || $0.gitRootPath == selectedPath }) {
            return selected
        }
        if let issue {
            for label in issue.labels {
                let lower = label.lowercased()
                guard lower.hasPrefix("proj:") else { continue }
                let slug = String(lower.dropFirst("proj:".count)).trimmingCharacters(in: .whitespaces)
                if !slug.isEmpty,
                   let match = discoveredProjects.first(where: { $0.name.lowercased() == slug }) {
                    return match
                }
            }
            if let branch = issue.branchName?.lowercased(), !branch.isEmpty,
               let match = discoveredProjects.first(where: { branch.contains($0.name.lowercased()) }) {
                return match
            }
            let haystack = ([issue.title, issue.description ?? "", issue.branchName ?? ""] + issue.labels)
                .joined(separator: " ")
                .lowercased()
            if let match = discoveredProjects.first(where: { haystack.contains($0.name.lowercased()) }) {
                return match
            }
        }
        return discoveredProjects.first
    }

    private func gitRootPath(for path: String) -> String? {
        runCommand("/usr/bin/git", ["-C", path, "rev-parse", "--show-toplevel"])
    }

    private func primaryLanguage(markers: [String]) -> String? {
        if markers.contains(where: { $0.hasSuffix(".xcodeproj") || $0 == "Package.swift" }) { return "Swift" }
        if markers.contains("package.json") { return "JavaScript" }
        if markers.contains("pyproject.toml") || markers.contains("requirements.txt") { return "Python" }
        if markers.contains("Cargo.toml") { return "Rust" }
        if markers.contains("go.mod") { return "Go" }
        if markers.contains("mix.exs") { return "Elixir" }
        if markers.contains("Gemfile") { return "Ruby" }
        if markers.contains("pom.xml") || markers.contains("build.gradle") { return "Java" }
        return nil
    }

    private func inferredCommands(markers: [String]) -> (build: String?, test: String?) {
        if let project = markers.first(where: { $0.hasSuffix(".xcodeproj") }) {
            let scheme = String(project.dropLast(".xcodeproj".count))
            return (
                "xcodebuild -project \(shellQuote(project)) -scheme \(shellQuote(scheme)) -destination 'platform=macOS' build",
                "xcodebuild -project \(shellQuote(project)) -scheme \(shellQuote(scheme)) -destination 'platform=macOS' test"
            )
        }
        if markers.contains("Package.swift") { return ("swift build", "swift test") }
        if markers.contains("package.json") { return ("npm run build", "npm test") }
        if markers.contains("pyproject.toml") { return (nil, "pytest") }
        if markers.contains("Cargo.toml") { return ("cargo build", "cargo test") }
        if markers.contains("go.mod") { return ("go build ./...", "go test ./...") }
        if markers.contains("mix.exs") { return ("mix compile", "mix test") }
        return (nil, nil)
    }

    private func expandedPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return path.replacingOccurrences(
                of: "~",
                with: FileManager.default.homeDirectoryForCurrentUser.path,
                options: [.anchored]
            )
        }
        return path
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runCommand(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    private func shellCommand(_ command: String) -> String? {
        runCommand("/bin/zsh", ["-lc", command])
    }

    private func dispatchError(_ message: String) -> NSError {
        NSError(domain: "AIDispatch", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func fetchIssues(workflow: AIWorkflowDefinition) async throws -> [AIIssue] {
        switch workflow.config.tracker.kind {
        case "linear":
            return try await AILinearClient(config: workflow.config.tracker).fetchCandidateIssues()
        case "local":
            return await localIssues()
        default:
            return await localIssues()
        }
    }

    private func fetchIssueStatesByIDs(_ ids: [String], workflow: AIWorkflowDefinition) async throws -> [AIIssue] {
        guard !ids.isEmpty else { return [] }
        switch workflow.config.tracker.kind {
        case "linear":
            return try await AILinearClient(config: workflow.config.tracker).fetchIssueStatesByIDs(ids)
        default:
            let idSet = Set(ids)
            return try await localIssueDocuments().map(\.issue).filter {
                idSet.contains($0.id) || idSet.contains($0.identifier)
            }
        }
    }

    private func fetchIssuesByStates(_ states: [String], workflow: AIWorkflowDefinition) async throws -> [AIIssue] {
        switch workflow.config.tracker.kind {
        case "linear":
            return try await AILinearClient(config: workflow.config.tracker).fetchIssuesByStates(states)
        default:
            let stateSet = Set(states.map(normalizeState))
            return try await localIssueDocuments().map(\.issue).filter {
                stateSet.contains($0.normalizedState)
            }
        }
    }

    private func fallbackIssues() async -> [AIIssue] {
        await localIssues()
    }

    private func loadWorkflow() -> AIWorkflowDefinition {
        if let workflowURL = resolveWorkflowMarkdownURL() {
            do {
                let parsed = try parseWorkflowMarkdownFile(at: workflowURL)
                let normalized = normalizedAppConfig(parsed.config)
                lastAppConfig = normalized
                return AIWorkflowDefinition(
                    path: workflowURL.path,
                    config: normalized.workflow,
                    promptTemplate: normalized.promptTemplate,
                    parseError: parsed.parseError,
                    loadedAt: Date(),
                    loadedFrom: .workflowMarkdown
                )
            } catch {
                appendLog(.error, "WORKFLOW.md load failed at \(workflowURL.path): \(error.localizedDescription). Keeping last good config.")
                if let fallback = lastWorkflow {
                    var copy = fallback
                    copy.parseError = error.localizedDescription
                    copy.loadedAt = Date()
                    return copy
                }
                return AIWorkflowDefinition(
                    path: workflowURL.path,
                    config: AIConfig.defaults(workflowDirectory: rootURL),
                    promptTemplate: "",
                    parseError: error.localizedDescription,
                    loadedAt: Date(),
                    loadedFrom: .workflowMarkdown
                )
            }
        }
        let defaults = AIAppConfig.defaults(rootURL: rootURL)
        lastAppConfig = defaults
        return AIWorkflowDefinition(
            path: FileManager.default.currentDirectoryPath,
            config: defaults.workflow,
            promptTemplate: defaults.promptTemplate,
            parseError: "WORKFLOW.md not found. Set SYMPHONY_WORKFLOW_PATH or run Geo from a directory containing WORKFLOW.md.",
            loadedAt: Date(),
            loadedFrom: .workflowMarkdown
        )
    }

    private func resolveWorkflowMarkdownURL() -> URL? {
        let fm = FileManager.default
        if let envPath = ProcessInfo.processInfo.environment["SYMPHONY_WORKFLOW_PATH"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let resolved = (envPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: resolved)
            if fm.fileExists(atPath: url.path) { return url }
        }
        for base in workflowSearchRoots() {
            if let url = nearestWorkflowMarkdown(from: base, fileManager: fm) {
                return url
            }
        }
        return nil
    }

    private func workflowSearchRoots() -> [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent()
        let bundle = Bundle.main.bundleURL
        let candidates = [cwd, source, rootURL, bundle]
        return candidates.reduce(into: [URL]()) { result, url in
            let standardized = url.standardizedFileURL
            guard !result.contains(where: { $0.path == standardized.path }) else { return }
            result.append(standardized)
        }
    }

    private func nearestWorkflowMarkdown(from startURL: URL, fileManager: FileManager) -> URL? {
        var current = startURL.hasDirectoryPath ? startURL : startURL.deletingLastPathComponent()
        while true {
            let candidate = current.appendingPathComponent("WORKFLOW.md")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    private func parseWorkflowMarkdownFile(at url: URL) throws -> AIParsedWorkflowFile {
        let content = try String(contentsOf: url, encoding: .utf8)
        var promptBody = content
        var configMap: [String: Any] = [:]
        if content.hasPrefix("---") {
            let lines = content.components(separatedBy: "\n")
            var endIndex: Int?
            for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = i
                break
            }
            guard let endIdx = endIndex else {
                throw NSError(domain: "AISymphony.Workflow", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "WORKFLOW.md front matter is missing closing '---'."
                ])
            }
            let yamlText = lines[1..<endIdx].joined(separator: "\n")
            let bodyLines = endIdx + 1 < lines.count ? Array(lines[(endIdx + 1)...]) : []
            let bodyText = bodyLines.joined(separator: "\n")
            configMap = try parseYAMLOrJSON(yamlText)
            promptBody = bodyText
        }
        let baseConfig = AIAppConfig.defaults(rootURL: rootURL)
        let merged = applyWorkflowOverrides(into: baseConfig, overrides: configMap)
        var finalConfig = merged
        let trimmedPrompt = promptBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            finalConfig.promptTemplate = trimmedPrompt
        }
        return AIParsedWorkflowFile(config: finalConfig, parseError: nil)
    }

    private func parseYAMLOrJSON(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        if trimmed.first == "{" {
            if let data = trimmed.data(using: .utf8),
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            throw NSError(domain: "AISymphony.Workflow", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "WORKFLOW.md front matter looked like JSON but failed to parse."
            ])
        }
        return try AISimpleYAMLParser.parse(trimmed)
    }

    private func applyWorkflowOverrides(into base: AIAppConfig, overrides: [String: Any]) -> AIAppConfig {
        var copy = base
        if let tracker = overrides["tracker"] as? [String: Any] {
            if let kind = tracker["kind"] as? String { copy.workflow.tracker.kind = kind }
            if let endpoint = tracker["endpoint"] as? String { copy.workflow.tracker.endpoint = endpoint }
            if let apiKey = tracker["api_key"] as? String { copy.workflow.tracker.apiKey = apiKey }
            else if let apiKey = tracker["apiKey"] as? String { copy.workflow.tracker.apiKey = apiKey }
            if let slug = tracker["project_slug"] as? String { copy.workflow.tracker.projectSlug = slug }
            else if let slug = tracker["projectSlug"] as? String { copy.workflow.tracker.projectSlug = slug }
            if let active = tracker["active_states"] as? [String] { copy.workflow.tracker.activeStates = active }
            else if let active = tracker["activeStates"] as? [String] { copy.workflow.tracker.activeStates = active }
            if let terminal = tracker["terminal_states"] as? [String] { copy.workflow.tracker.terminalStates = terminal }
            else if let terminal = tracker["terminalStates"] as? [String] { copy.workflow.tracker.terminalStates = terminal }
        }
        if let polling = overrides["polling"] as? [String: Any] {
            if let interval = polling["interval_ms"] as? Int { copy.workflow.polling.intervalMS = interval }
            else if let interval = polling["intervalMS"] as? Int { copy.workflow.polling.intervalMS = interval }
        }
        if let workspace = overrides["workspace"] as? [String: Any] {
            if let root = workspace["root"] as? String {
                copy.workflow.workspace.root = (root as NSString).expandingTildeInPath
            }
        }
        if let hooks = overrides["hooks"] as? [String: Any] {
            if let s = hooks["after_create"] as? String { copy.workflow.hooks.afterCreate = s }
            if let s = hooks["before_run"] as? String { copy.workflow.hooks.beforeRun = s }
            if let s = hooks["after_run"] as? String { copy.workflow.hooks.afterRun = s }
            if let s = hooks["before_remove"] as? String { copy.workflow.hooks.beforeRemove = s }
            if let i = hooks["timeout_ms"] as? Int { copy.workflow.hooks.timeoutMS = i }
        }
        if let agent = overrides["agent"] as? [String: Any] {
            if let n = agent["max_concurrent_agents"] as? Int { copy.workflow.agent.maxConcurrentAgents = n }
            else if let n = agent["maxConcurrentAgents"] as? Int { copy.workflow.agent.maxConcurrentAgents = n }
            if let n = agent["max_turns"] as? Int { copy.workflow.agent.maxTurns = n }
            else if let n = agent["maxTurns"] as? Int { copy.workflow.agent.maxTurns = n }
            if let n = agent["max_retry_backoff_ms"] as? Int { copy.workflow.agent.maxRetryBackoffMS = n }
            if let map = agent["max_concurrent_agents_by_state"] as? [String: Int] {
                copy.workflow.agent.maxConcurrentAgentsByState = map
            }
        }
        if let pi = overrides["pi"] as? [String: Any] {
            if let s = pi["model"] as? String { copy.workflow.pi.model = s }
            if let s = pi["effort"] as? String { copy.workflow.pi.effort = s }
            if let i = pi["turn_timeout_ms"] as? Int { copy.workflow.pi.turnTimeoutMS = i }
            if let i = pi["stall_timeout_ms"] as? Int { copy.workflow.pi.stallTimeoutMS = i }
        }
        return copy
    }

    private func normalizedAppConfig(_ config: AIAppConfig) -> AIAppConfig { config }

    private func continuationPromptTemplate(base: String) -> String {
        """
        Continuation of task {{ issue.identifier }} (turn {{ attempt }}). You already have the full prior conversation in this session via --session; do not re-derive context.

        The human reviewed your last report. Their reply is the `## User Request` section of the latest task node below. Address it directly.

        Latest task node:
        {{ issue.node_markdown }}

        `## Brief` and `## Acceptance Criteria` are optional context — they may be empty, placeholder text (e.g. "Write the task brief here."), or fully specified. Treat them as hints, not gates. Do not refuse, stall, or flag the run because Brief is unset or looks like a placeholder. Acceptance Criteria is human-owned; only the human edits those checkboxes.

        When done, overwrite the report at:
        {{ agent.report_path }}

        The FIRST section of the report MUST be `## Progress` — a markdown checklist of the concrete steps you took this turn (use `- [x]` for completed, `- [ ]` only when deferred). 5–12 items typical, each verifiable (e.g. "Read X", "Updated Y line N", "Ran Z").

        After `## Progress`, include: summary, files changed, validation, risks, next recommended state. Then exit.

        Formatting rules — the Geo viewer is a thin Markdown renderer:
        - Do NOT use Markdown tables. Use bullet lists. For `## Files Changed`, one bullet per file: `- path/to/file — what changed`.
        - For `## Next Recommended State`, the FIRST word of the body must be one of: Backlog, Todo, In Progress, Human Review, Rework, Merging, Done, Canceled. The viewer parses this for a one-click transition button.
        """
    }

    private func renderPrompt(
        template: String,
        issue: AIIssue,
        nodeMarkdown: String = "",
        attempt: Int,
        project: AIDiscoveredProject? = nil,
        agentWorkspacePath: String? = nil
    ) throws -> String {
        var output = template
        let projectName = project?.name ?? ""
        let projectPath = project?.rootPath ?? ""
        let values: [String: String] = [
            "{{ issue.id }}": issue.id,
            "{{ issue.identifier }}": issue.identifier,
            "{{ issue.title }}": issue.title,
            "{{ issue.description }}": issue.description ?? "",
            "{{ issue.node_markdown }}": relabelNextPromptHeading(in: nodeMarkdown),
            "{{ issue.linked_block_id }}": issue.linkedBlockID ?? "",
            "{{ issue.state }}": issue.state,
            "{{ issue.url }}": issue.url ?? "",
            "{{ issue.branch_name }}": issue.branchName ?? "",
            "{{ attempt }}": "\(attempt)",
            "{{ project.name }}": projectName,
            "{{ project.path }}": projectPath,
            "{{ project.markers }}": project?.markerSummary ?? "",
            "{{ agent.name }}": AIAgentKind.pi.rawValue,
            "{{ agent.display_name }}": AIAgentKind.pi.displayName,
            "{{ agent.workspace_path }}": agentWorkspacePath ?? "",
            "{{ agent.report_path }}": reportPath(forAgentWorkspacePath: agentWorkspacePath)
        ]
        for (token, value) in values {
            output = output.replacingOccurrences(of: token, with: value)
        }
        let rPath = values["{{ agent.report_path }}"] ?? ""
        if !rPath.isEmpty && !output.contains(rPath) {
            output += """


            Before finishing, write a concise Markdown report to:
            \(rPath)

            Include: summary, files changed, validation, risks, and next recommended state.
            """
        }
        if let range = output.range(of: #"\{\{[^}]+\}\}"#, options: .regularExpression) {
            let token = String(output[range])
            throw dispatchError("Unknown prompt token: \(token)")
        }
        return output
    }

    private func scheduleRetry(issueID: String, workflow: AIWorkflowDefinition, abnormal: Bool) {
        let maxBackoffMS = workflow.config.agent.maxRetryBackoffMS
        let bucket = attemptsByIssueID[issueID] ?? []
        let delayMS: Int
        if abnormal {
            let attemptNumber = bucket.lazy.map(\.attempt).max() ?? 1
            let base = 10_000 * Int(pow(2.0, Double(max(attemptNumber - 1, 0))))
            delayMS = maxBackoffMS > 0 ? min(base, maxBackoffMS) : base
        } else {
            delayMS = 1_000
        }
        let dueAt = Date().addingTimeInterval(Double(delayMS) / 1000.0)
        let attemptNumber = bucket.lazy.map(\.attempt).max() ?? 0
        let lastError = bucket
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }.first?.error
        retryEntries[issueID] = AIRetryEntry(
            issueID: issueID,
            identifier: identifier(for: issueID),
            attempt: attemptNumber,
            dueAt: dueAt,
            error: lastError
        )
        claimedIssueIDs.insert(issueID)
        retryTasks[issueID]?.cancel()
        retryTasks[issueID] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000) } catch { return }
            await self?.fireRetry(issueID: issueID)
        }
        appendLog(.info, "\(identifier(for: issueID)) retry in \(delayMS / 1_000)s (abnormal: \(abnormal)).")
    }

    private func fireRetry(issueID: String) async {
        retryEntries.removeValue(forKey: issueID)
        retryTasks.removeValue(forKey: issueID)
        let workflow = await currentWorkflow()
        guard let issue = lastIssues.first(where: { $0.id == issueID }) else {
            claimedIssueIDs.remove(issueID)
            appendLog(.info, "Retry cancelled for \(issueID): issue gone.")
            return
        }
        let maxTurns = max(workflow.config.agent.maxTurns, 1)
        let attemptCount = attempts.filter { $0.issueID == issueID }.count
        guard attemptCount < maxTurns else {
            claimedIssueIDs.remove(issueID)
            appendLog(.warning, "Retry cancelled for \(issue.identifier): hit max_turns (\(maxTurns)).")
            return
        }
        guard isEligible(issue, workflow: workflow) else {
            claimedIssueIDs.remove(issueID)
            appendLog(.info, "Retry cancelled for \(issue.identifier): no longer eligible.")
            return
        }
        let maxAgents = max(workflow.config.agent.maxConcurrentAgents, 1)
        guard liveSessions.count < maxAgents else {
            scheduleRetry(issueID: issueID, workflow: workflow, abnormal: false)
            retryEntries[issueID]?.error = "no available orchestrator slots"
            appendLog(.info, "No slots for \(issue.identifier) retry; re-queuing.")
            return
        }
        claimedIssueIDs.remove(issueID)
        await dispatch(issue: issue, workflow: workflow, forcedProject: nil)
    }

    private func detectStalls(workflow: AIWorkflowDefinition) {
        let stallTimeoutMS = workflow.config.pi.stallTimeoutMS
        guard stallTimeoutMS > 0 else { return }
        let now = Date()
        var stalled: [(issueID: String, identifier: String, elapsedS: Int)] = []

        for (sessionID, session) in liveSessions {
            let lastActive = session.lastTimestamp ?? session.startedAt
            let elapsedMS = now.timeIntervalSince(lastActive) * 1000
            guard elapsedMS > Double(stallTimeoutMS) else { continue }
            removeLiveSession(sessionID: sessionID)
            claimedIssueIDs.remove(session.issueID)
            markAttempt(issueID: session.issueID, status: .stalled, error: "No activity for \(stallTimeoutMS / 1_000)s.")
            stalled.append((session.issueID, session.issueIdentifier, Int(elapsedMS / 1_000)))
        }
        for entry in stalled {
            appendLog(.warning, "\(entry.identifier) stalled after \(entry.elapsedS)s; requeueing.")
            scheduleRetry(issueID: entry.issueID, workflow: workflow, abnormal: true)
        }
    }

    private func startupTerminalCleanup(workflow: AIWorkflowDefinition) async {
        do {
            let terminalIssues: [AIIssue]
            switch workflow.config.tracker.kind {
            case "linear":
                terminalIssues = try await AILinearClient(config: workflow.config.tracker).fetchTerminalIssues()
            default:
                let terminalStates = Set(workflow.config.tracker.terminalStates.map(normalizeState))
                terminalIssues = try await localIssueDocuments().map(\.issue).filter { terminalStates.contains($0.normalizedState) }
            }
            for issue in terminalIssues { cleanupWorkspace(issueID: issue.id) }
            if !terminalIssues.isEmpty {
                appendLog(.info, "Startup cleanup: removed workspaces for \(terminalIssues.count) terminal issue(s).")
            }
        } catch {
            appendLog(.warning, "Startup terminal cleanup failed: \(error.localizedDescription)")
        }
    }

    private func startConfigWatcher() {
        let workflowMarkdownPaths = workflowMarkdownWatchPaths()
        let watchURL = workflowMarkdownPaths.first
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let watcher = FileWatcherService(url: watchURL, latency: 0.5)
        watcher.onChange = { [weak self] urls in
            let matchedWorkflow = urls.contains(where: { workflowMarkdownPaths.contains($0.path) })
            guard matchedWorkflow else { return }
            Task { [weak self] in await self?.handleConfigChange() }
        }
        watcher.start()
        configWatcher = watcher
        workflowFileWatcher = nil
    }

    private func workflowMarkdownWatchPaths() -> [String] {
        var paths: [String] = []
        if let resolved = resolveWorkflowMarkdownURL()?.path {
            paths.append(resolved)
        }
        let cwd = FileManager.default.currentDirectoryPath
        paths.append(URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent("WORKFLOW.md").path)
        if let envPath = ProcessInfo.processInfo.environment["SYMPHONY_WORKFLOW_PATH"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let resolved = (envPath as NSString).expandingTildeInPath
            paths.append(URL(fileURLWithPath: resolved).path)
        }
        return paths.reduce(into: [String]()) { result, path in
            guard !result.contains(path) else { return }
            result.append(path)
        }
    }

    private func handleConfigChange() async {
        lastWorkflow = loadWorkflow()
        appendLog(.info, "Config reloaded automatically (WORKFLOW.md changed).")
    }

    private func reportPath(forAgentWorkspacePath path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(".symphony", isDirectory: true)
            .appendingPathComponent("report.md")
            .path
    }

    private func nextAttemptNumber(for issueID: String) -> Int {
        let bucket = attemptsByIssueID[issueID] ?? []
        let highest = bucket.lazy.filter { $0.status != .preparing }.map(\.attempt).max() ?? 0
        return highest + 1
    }

    private func insertAttempt(_ attempt: AIRunAttempt, at index: Int) {
        attempts.insert(attempt, at: index)
        attemptsByIssueID[attempt.issueID, default: []].append(attempt)
    }

    private func removeAttempt(at index: Int) {
        let removed = attempts.remove(at: index)
        guard var bucket = attemptsByIssueID[removed.issueID] else { return }
        if let i = bucket.firstIndex(where: { $0.id == removed.id }) {
            bucket.remove(at: i)
        }
        if bucket.isEmpty {
            attemptsByIssueID.removeValue(forKey: removed.issueID)
        } else {
            attemptsByIssueID[removed.issueID] = bucket
        }
    }

    private func mutateAttempt(at index: Int, _ body: (inout AIRunAttempt) -> Void) {
        body(&attempts[index])
        let updated = attempts[index]
        guard var bucket = attemptsByIssueID[updated.issueID],
              let i = bucket.firstIndex(where: { $0.id == updated.id }) else { return }
        bucket[i] = updated
        attemptsByIssueID[updated.issueID] = bucket
    }

    private func registerLiveSession(_ session: AILiveSession) {
        liveSessions[session.sessionID] = session
        liveSessionsByIssueID[session.issueID, default: []].insert(session.sessionID)
    }

    private func removeLiveSession(sessionID: String) {
        guard let removed = liveSessions.removeValue(forKey: sessionID) else { return }
        guard var bucket = liveSessionsByIssueID[removed.issueID] else { return }
        bucket.remove(sessionID)
        if bucket.isEmpty {
            liveSessionsByIssueID.removeValue(forKey: removed.issueID)
        } else {
            liveSessionsByIssueID[removed.issueID] = bucket
        }
    }

    private func removeLiveSessions(forIssueID issueID: String) {
        guard let sessionIDs = liveSessionsByIssueID.removeValue(forKey: issueID) else { return }
        for sessionID in sessionIDs {
            liveSessions.removeValue(forKey: sessionID)
        }
    }

    private func markAttempt(issueID: String, status: AIRunStatus, error: String?) {
        guard let index = attempts.firstIndex(where: { $0.issueID == issueID && $0.finishedAt == nil }) else { return }
        mutateAttempt(at: index) { attempt in
            attempt.status = status
            attempt.error = error
            if status != .running && status != .launching && status != .preparing {
                attempt.finishedAt = Date()
                if let sessionIDs = liveSessionsByIssueID[issueID],
                   let firstSessionID = sessionIDs.first,
                   let session = liveSessions[firstSessionID],
                   !session.recentToolCalls.isEmpty {
                    attempt.toolCalls = session.recentToolCalls
                }
            }
        }
    }

    private func appendLog(_ level: AILogLevel, _ message: String) {
        let formatted = "level=\(level.rawValue) message=\"\(message.replacingOccurrences(of: "\"", with: "\\\""))\""
        logs.insert(AILogEntry(level: level, message: formatted), at: 0)
        if logs.count > 200 {
            logs.removeLast(logs.count - 200)
        }
        aiLogger.info("\(formatted, privacy: .public)")
    }

    private func sortedIssues(_ issues: [AIIssue]) -> [AIIssue] {
        issues.sorted {
            if $0.prioritySortValue != $1.prioritySortValue {
                return $0.prioritySortValue < $1.prioritySortValue
            }
            if ($0.createdAt ?? .distantFuture) != ($1.createdAt ?? .distantFuture) {
                return ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture)
            }
            return $0.identifier < $1.identifier
        }
    }

    private func sanitizeWorkspaceKey(_ identifier: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return String(identifier.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }

    private func normalizeState(_ state: String) -> String {
        state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func identifier(for issueID: String) -> String {
        lastIssues.first(where: { $0.id == issueID })?.identifier ?? issueID
    }
}

private struct AILinearClient {
    let config: AITrackerConfig

    func fetchTerminalIssues() async throws -> [AIIssue] {
        try await fetchIssuesByStates(config.terminalStates)
    }

    func fetchCandidateIssues() async throws -> [AIIssue] {
        try await fetchIssuesByStates(config.activeStates)
    }

    func fetchIssuesByStates(_ states: [String]) async throws -> [AIIssue] {
        guard let apiKey = config.resolvedAPIKey, !apiKey.isEmpty else {
            throw AILinearError.missingAPIKey
        }
        guard let projectSlug = config.projectSlug, !projectSlug.isEmpty else {
            throw AILinearError.missingProjectSlug
        }

        var issues: [AIIssue] = []
        var cursor: String?

        repeat {
            var variables: [String: Any] = [
                "projectSlug": projectSlug,
                "stateNames": states,
                "first": 50,
                "relationFirst": 50
            ]
            if let cursor {
                variables["after"] = cursor
            }

            let body = try await graphql(query: Self.query, variables: variables, apiKey: apiKey)

            let page = try parsePage(body)
            issues.append(contentsOf: page.issues)
            cursor = page.nextCursor
        } while cursor != nil

        return issues
    }

    func fetchIssueStatesByIDs(_ ids: [String]) async throws -> [AIIssue] {
        guard let apiKey = config.resolvedAPIKey, !apiKey.isEmpty else {
            throw AILinearError.missingAPIKey
        }
        let chunks = stride(from: 0, to: ids.count, by: 50).map {
            Array(ids[$0..<min($0 + 50, ids.count)])
        }
        var issues: [AIIssue] = []
        for chunk in chunks {
            let variables: [String: Any] = [
                "ids": chunk,
                "first": 50,
                "relationFirst": 50
            ]
            let body = try await graphql(query: Self.byIDsQuery, variables: variables, apiKey: apiKey)
            issues.append(contentsOf: try parsePage(body).issues)
        }
        return issues
    }

    private func graphql(query: String, variables: [String: Any], apiKey: String) async throws -> [String: Any] {
        guard let url = URL(string: config.endpoint) else { throw AILinearError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "query": query,
            "variables": variables
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AILinearError.requestFailed
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AILinearError.invalidResponse
        }
        return json
    }

    private func parsePage(_ body: [String: Any]) throws -> (issues: [AIIssue], nextCursor: String?) {
        guard let data = body["data"] as? [String: Any],
              let issuesPayload = data["issues"] as? [String: Any],
              let nodes = issuesPayload["nodes"] as? [[String: Any]] else {
            throw AILinearError.invalidResponse
        }

        let pageInfo = issuesPayload["pageInfo"] as? [String: Any]
        let hasNext = pageInfo?["hasNextPage"] as? Bool ?? false
        let nextCursor = hasNext ? pageInfo?["endCursor"] as? String : nil
        return (nodes.compactMap(parseIssue), nextCursor)
    }

    private func parseIssue(_ node: [String: Any]) -> AIIssue? {
        guard let id = node["id"] as? String,
              let identifier = node["identifier"] as? String,
              let title = node["title"] as? String else { return nil }

        let state = (node["state"] as? [String: Any])?["name"] as? String ?? "Todo"
        let labelsPayload = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let labels = labelsPayload.compactMap { ($0["name"] as? String)?.lowercased() }
        let relations = ((node["inverseRelations"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let blockers = relations.compactMap(parseBlocker)

        return AIIssue(
            id: id,
            identifier: identifier,
            title: title,
            description: node["description"] as? String,
            priority: node["priority"] as? Int,
            state: state,
            branchName: node["branchName"] as? String,
            url: node["url"] as? String,
            labels: labels,
            blockedBy: blockers,
            createdAt: parseDate(node["createdAt"] as? String),
            updatedAt: parseDate(node["updatedAt"] as? String),
            linkedBlockID: nil
        )
    }

    private func parseBlocker(_ relation: [String: Any]) -> AIBlocker? {
        guard relation["type"] as? String == "blocks",
              let issue = relation["issue"] as? [String: Any] else { return nil }
        return AIBlocker(
            trackerID: issue["id"] as? String,
            identifier: issue["identifier"] as? String,
            state: (issue["state"] as? [String: Any])?["name"] as? String,
            createdAt: nil,
            updatedAt: nil
        )
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static let query = """
    query AILinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
      issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
        nodes {
          id
          identifier
          title
          description
          priority
          state { name }
          branchName
          url
          labels { nodes { name } }
          inverseRelations(first: $relationFirst) {
            nodes {
              type
              issue { id identifier state { name } }
            }
          }
          createdAt
          updatedAt
        }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    private static let byIDsQuery = """
    query AILinearIssueStatesByIDs($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
      issues(filter: {id: {in: $ids}}, first: $first) {
        nodes {
          id
          identifier
          title
          description
          priority
          state { name }
          branchName
          url
          labels { nodes { name } }
          inverseRelations(first: $relationFirst) {
            nodes {
              type
              issue { id identifier state { name } }
            }
          }
          createdAt
          updatedAt
        }
        pageInfo { hasNextPage endCursor }
      }
    }
    """
}

private enum AILinearError: LocalizedError {
    case missingAPIKey
    case missingProjectSlug
    case invalidEndpoint
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Linear API key is missing."
        case .missingProjectSlug: return "Linear project slug is missing."
        case .invalidEndpoint: return "Linear endpoint is invalid."
        case .requestFailed: return "Linear request failed."
        case .invalidResponse: return "Linear returned an invalid response."
        }
    }
}
