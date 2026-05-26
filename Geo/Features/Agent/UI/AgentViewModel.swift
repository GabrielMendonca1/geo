import Combine
import Foundation
import SwiftUI

@MainActor
final class AIViewModel: ObservableObject {
    @Published private(set) var snapshot: AISnapshot?
    @Published private(set) var isBusy = false
    @Published var selectedIssueID: String?
    @Published var selectedProjectID: String?
    @Published var selectedState: String = "Todo"
    @Published var pinnedHiddenStates: Set<String> = []
    @Published var errorMessage: String?

    func toggleHiddenState(_ state: String) {
        let key = state.lowercased()
        if pinnedHiddenStates.contains(key) {
            pinnedHiddenStates.remove(key)
        } else {
            pinnedHiddenStates.insert(key)
        }
    }

    func isHiddenStatePinned(_ state: String) -> Bool {
        pinnedHiddenStates.contains(state.lowercased())
    }

    private var repository: (any AIRepository)?
    private var refreshTask: Task<Void, Never>?
    private var isBound = false

    deinit {
        refreshTask?.cancel()
    }

    func bindIfNeeded(repository: any AIRepository) {
        guard !isBound else { return }
        isBound = true
        self.repository = repository

        Task { await perform { await repository.startService() } }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let hasLive = await MainActor.run { self?.snapshot?.liveSessions.isEmpty == false }
                let interval: UInt64 = hasLive ? 1_500_000_000 : 5_000_000_000
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                await self?.refresh(fetchIssues: false)
            }
        }
    }

    func refresh(fetchIssues: Bool = false) async {
        guard let repository else { return }
        if fetchIssues {
            await perform { await repository.pollNow() }
        } else {
            snapshot = await repository.snapshot()
            validateSelection()
        }
    }

    func startService() {
        guard let repository else { return }
        Task { await perform { await repository.startService() } }
    }

    func stopService() {
        guard let repository else { return }
        Task { await perform { await repository.stopService() } }
    }

    func reloadWorkflow() {
        guard let repository else { return }
        Task { await perform { await repository.reloadWorkflow() } }
    }

    func scanProjects() {
        guard let repository else { return }
        Task { await perform { await repository.scanProjects() } }
    }

    func selectProject(id: String) {
        selectedProjectID = id
        guard let repository else { return }
        Task { await perform { await repository.selectProject(id: id) } }
    }

    func setProjectAgentEnabled(projectID: String, agent: String, enabled: Bool) {
        guard let repository else { return }
        guard let kind = AIAgentKind(rawValue: agent) else {
            errorMessage = "Unknown agent runtime: \(agent)."
            return
        }
        Task {
            await perform {
                await repository.setProjectAgentEnabled(projectID: projectID, agent: kind, enabled: enabled)
            }
        }
    }

    func createIssue(
        title: String,
        description: String,
        projectID: String?,
        runNow: Bool,
        model: String? = nil,
        effort: String? = nil,
        openLinkedNode: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        guard let repository else { return }
        let existingIssueIDs = Set(snapshot?.issues.map(\.id) ?? [])
        Task {
            isBusy = true
            errorMessage = nil
            if let projectID {
                _ = await repository.selectProject(id: projectID)
            }
            let updated = await repository.createIssue(title: title, description: description, model: model, effort: effort)
            snapshot = updated
            let created = updated.issues.first { !existingIssueIDs.contains($0.id) } ?? updated.issues.first
            if let created {
                selectedIssueID = created.id
                selectedState = created.state
                validateProjectSelection()
                if let linkedBlockID = created.linkedBlockID {
                    openLinkedNode(linkedBlockID)
                }
                if runNow {
                    let dispatched = await repository.dispatch(issueID: created.id)
                    snapshot = dispatched
                }
            } else {
                validateSelection()
            }
            isBusy = false
        }
    }

    func updateIssueState(issueID: String, state: String) {
        guard let repository else { return }
        Task { await perform { await repository.updateIssueState(issueID: issueID, state: state) } }
    }

    func setIssueModel(issueID: String, model: String?) {
        guard let repository else { return }
        Task { await perform { await repository.setIssueModel(issueID: issueID, model: model) } }
    }

    func setIssueEffort(issueID: String, effort: String?) {
        guard let repository else { return }
        Task { await perform { await repository.setIssueEffort(issueID: issueID, effort: effort) } }
    }

    func pollNow() {
        guard let repository else { return }
        Task { await perform { await repository.pollNow() } }
    }

    func dispatch(issueID: String) {
        guard let repository else { return }
        Task { await perform { await repository.dispatch(issueID: issueID) } }
    }

    func release(issueID: String) {
        guard let repository else { return }
        Task { await perform { await repository.release(issueID: issueID) } }
    }

    func deleteIssue(issueID: String) {
        guard let repository else { return }
        Task { await perform { await repository.deleteIssue(issueID: issueID) } }
    }

    func openWorkflow() {
        guard let repository else { return }
        Task { await repository.openWorkflow() }
    }

    func openLinkedNode(for issue: AIIssue, openLinkedNode: @escaping @MainActor (String) -> Void) {
        select(issue)
        if let linkedBlockID = issue.linkedBlockID {
            openLinkedNode(linkedBlockID)
            return
        }

        guard let repository else { return }
        Task {
            if let linkedBlockID = await repository.ensureIssueNode(issueID: issue.id) {
                let fresh = await repository.snapshot()
                await MainActor.run {
                    snapshot = fresh
                    openLinkedNode(linkedBlockID)
                }
            }
        }
    }

    func openProject(projectID: String) {
        guard let repository else { return }
        Task { await repository.openProject(projectID: projectID) }
    }

    func openWorkspace(issueID: String) {
        guard let repository else { return }
        Task { await repository.openWorkspace(issueID: issueID) }
    }

    func select(_ issue: AIIssue) {
        selectedIssueID = issue.id
        selectedState = issue.state
    }

    var selectedIssue: AIIssue? {
        guard let selectedIssueID else { return nil }
        return snapshot?.issues.first { $0.id == selectedIssueID }
    }

    var projects: [AgentProjectSummary] {
        snapshot?.agentProjectSummaries ?? []
    }

    var selectedProject: AgentProjectSummary? {
        guard !projects.isEmpty else { return nil }
        if let selectedProjectID,
           let project = projects.first(where: { $0.id == selectedProjectID }) {
            return project
        }
        return projects.first
    }

    var agentRuntimes: [AgentRuntimeSummary] {
        guard let snapshot else { return AgentRuntimeSummary.defaults() }
        return snapshot.agentRuntimeSummaries
    }

    var availableAgentCount: Int {
        agentRuntimes.filter(\.isAvailable).count
    }

    func enabledAgents(for project: AgentProjectSummary?) -> [AgentRuntimeSummary] {
        guard let project else { return [] }
        let enabled = project.enabledAgents
        return agentRuntimes.filter { enabled.contains($0.id) }
    }

    private func perform(_ operation: () async -> AISnapshot) async {
        isBusy = true
        errorMessage = nil
        snapshot = await operation()
        validateSelection()
        isBusy = false
    }

    private func validateSelection() {
        guard let snapshot else { return }
        if let selectedIssueID, !snapshot.issues.contains(where: { $0.id == selectedIssueID }) {
            self.selectedIssueID = nil
            selectedState = "Todo"
        }
        validateProjectSelection()
    }

    private func validateProjectSelection() {
        let projects = self.projects
        guard !projects.isEmpty else {
            selectedProjectID = nil
            return
        }
        if let selectedProjectID,
           projects.contains(where: { $0.id == selectedProjectID }) {
            return
        }
        selectedProjectID = projects.first?.id
    }
}

struct AgentProjectSummary: Identifiable, Hashable {
    var id: String
    var name: String
    var path: String?
    var language: String?
    var branch: String?
    var enabledAgents: Set<String>
}

struct AgentRuntimeSummary: Identifiable, Hashable {
    var id: String
    var name: String
    var isAvailable: Bool
    var version: String?
    var path: String?
    var detail: String?

    var statusText: String {
        if isAvailable { return "Available" }
        return detail ?? "Unavailable"
    }

    static func defaults() -> [AgentRuntimeSummary] {
        [
            AgentRuntimeSummary(
                id: "pi",
                name: "pi",
                isAvailable: false,
                version: nil,
                path: nil,
                detail: "Not scanned"
            )
        ]
    }
}

private extension AISnapshot {
    var agentProjectSummaries: [AgentProjectSummary] {
        projects.map { project in
            AgentProjectSummary(
                id: project.id,
                name: project.name,
                path: project.rootPath,
                language: project.primaryLanguage,
                branch: project.currentBranch,
                enabledAgents: Set(project.enabledAgents.map(\.rawValue))
            )
        }
    }

    var agentRuntimeSummaries: [AgentRuntimeSummary] {
        let parsed = agentRuntimes.map { runtime in
            return AgentRuntimeSummary(
                id: runtime.kind.rawValue,
                name: runtime.kind.label,
                isAvailable: runtime.isAvailable,
                version: runtime.version,
                path: runtime.executablePath,
                detail: runtime.statusDetail
            )
        }

        let defaults = AgentRuntimeSummary.defaults()
        return defaults.reduce(into: parsed) { result, fallback in
            if !result.contains(where: { $0.id == fallback.id }) {
                result.append(fallback)
            }
        }
    }
}
