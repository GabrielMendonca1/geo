import Foundation

protocol AIRepository: Sendable {
    func snapshot() async -> AISnapshot
    func startService() async -> AISnapshot
    func stopService() async -> AISnapshot
    func reloadWorkflow() async -> AISnapshot
    func pollNow() async -> AISnapshot
    func scanProjects() async -> AISnapshot
    func selectProject(id: String) async -> AISnapshot
    func setProjectAgentEnabled(projectID: String, agent: AIAgentKind, enabled: Bool) async -> AISnapshot
    func createIssue(title: String, description: String, model: String?, effort: String?) async -> AISnapshot
    func updateIssueState(issueID: String, state: String) async -> AISnapshot
    func dispatch(issueID: String) async -> AISnapshot
    func dispatchTask(title: String, description: String, projectID: String?) async -> AISnapshot
    func release(issueID: String) async -> AISnapshot
    func deleteIssue(issueID: String) async -> AISnapshot
    func setIssueModel(issueID: String, model: String?) async -> AISnapshot
    func setIssueEffort(issueID: String, effort: String?) async -> AISnapshot
    func setIssuePriority(issueID: String, priority: Int?) async -> AISnapshot
    func openWorkflow() async
    func openIssueNode(issueID: String) async
    func ensureIssueNode(issueID: String) async -> String?
    func openWorkspace(issueID: String) async
    func openProject(projectID: String) async
}
