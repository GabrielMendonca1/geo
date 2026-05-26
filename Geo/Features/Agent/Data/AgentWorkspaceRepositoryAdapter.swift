import AppKit
import Foundation

struct AIWorkspaceRepositoryAdapter: AIRepository, @unchecked Sendable {
    private let manager: AIWorkspaceManager
    private let discoveryStore = AIProjectDiscoveryStore.shared

    init(manager: AIWorkspaceManager) {
        self.manager = manager
    }

    func snapshot() async -> AISnapshot {
        await discoveryStore.enrich(await manager.snapshot())
    }

    func startService() async -> AISnapshot {
        await discoveryStore.enrich(await manager.startService())
    }

    func stopService() async -> AISnapshot {
        await discoveryStore.enrich(await manager.stopService())
    }

    func reloadWorkflow() async -> AISnapshot {
        await discoveryStore.enrich(await manager.reloadWorkflow())
    }

    func pollNow() async -> AISnapshot {
        await discoveryStore.enrich(await manager.pollNow())
    }

    func scanProjects() async -> AISnapshot {
        await discoveryStore.scanProjects()
        return await snapshot()
    }

    func selectProject(id: String) async -> AISnapshot {
        await discoveryStore.selectProject(id: id)
        return await snapshot()
    }

    func setProjectAgentEnabled(projectID: String, agent: AIAgentKind, enabled: Bool) async -> AISnapshot {
        await discoveryStore.setProjectAgentEnabled(projectID: projectID, agent: agent, enabled: enabled)
        return await snapshot()
    }

    func createIssue(title: String, description: String, model: String?, effort: String?) async -> AISnapshot {
        await discoveryStore.enrich(await manager.createIssue(title: title, description: description, model: model, effort: effort))
    }

    func updateIssueState(issueID: String, state: String) async -> AISnapshot {
        await discoveryStore.enrich(await manager.updateIssueState(issueID: issueID, state: state))
    }

    func dispatch(issueID: String) async -> AISnapshot {
        let project = await discoveryStore.selectedProject()
        return await discoveryStore.enrich(await manager.dispatch(issueID: issueID, project: project))
    }

    func dispatchTask(title: String, description: String, projectID: String?) async -> AISnapshot {
        let before = Set((await snapshot()).issues.map(\.id))
        let afterCreate = await createIssue(title: title, description: description, model: nil, effort: nil)
        guard let created = afterCreate.issues.first(where: { !before.contains($0.id) }) else {
            return afterCreate
        }
        if let projectID, !projectID.isEmpty {
            _ = await selectProject(id: projectID)
        }
        return await dispatch(issueID: created.id)
    }

    func release(issueID: String) async -> AISnapshot {
        await discoveryStore.enrich(await manager.release(issueID: issueID))
    }

    func deleteIssue(issueID: String) async -> AISnapshot {
        await discoveryStore.enrich(await manager.deleteIssue(issueID: issueID))
    }

    func setIssueModel(issueID: String, model: String?) async -> AISnapshot {
        await discoveryStore.enrich(await manager.setIssueModel(issueID: issueID, model: model))
    }

    func setIssueEffort(issueID: String, effort: String?) async -> AISnapshot {
        await discoveryStore.enrich(await manager.setIssueEffort(issueID: issueID, effort: effort))
    }

    func setIssuePriority(issueID: String, priority: Int?) async -> AISnapshot {
        await discoveryStore.enrich(await manager.setIssuePriority(issueID: issueID, priority: priority))
    }

    func openWorkflow() async {
        await manager.openWorkflow()
    }

    func openIssueNode(issueID: String) async {
        await manager.openIssueNode(issueID: issueID)
    }

    func ensureIssueNode(issueID: String) async -> String? {
        await manager.ensureIssueNode(issueID: issueID)
    }

    func openWorkspace(issueID: String) async {
        await manager.openWorkspace(issueID: issueID)
    }

    func openProject(projectID: String) async {
        guard let path = await discoveryStore.projectPath(for: projectID) else { return }
        await MainActor.run {
            _ = NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        }
    }
}

protocol AIProjectAttachable {
    var projectID: String? { get set }
    var projectName: String? { get set }
    var projectRootPath: String? { get set }
}

extension AIWorkspace: AIProjectAttachable {}
extension AIRunAttempt: AIProjectAttachable {}
extension AILiveSession: AIProjectAttachable {}

private extension AIProjectAttachable {
    func attaching(_ project: AIDiscoveredProject) -> Self {
        var copy = self
        copy.projectID = copy.projectID ?? project.id
        copy.projectName = copy.projectName ?? project.name
        copy.projectRootPath = copy.projectRootPath ?? project.rootPath
        return copy
    }
}

private actor AIProjectDiscoveryStore {
    static let shared = AIProjectDiscoveryStore()

    private var projects: [AIDiscoveredProject] = []
    private var selectedProjectID: String?
    private var agentRuntimes: [AIAgentRuntime] = []
    private let stateStore = AIProjectStateStore.shared

    func enrich(_ snapshot: AISnapshot) async -> AISnapshot {
        if agentRuntimes.isEmpty { agentRuntimes = detectAgentRuntimes() }

        let projectSource = projects.isEmpty ? snapshot.projects : projects
        let selectedID = selectedProjectID ?? snapshot.selectedProjectID ?? projectSource.first?.id
        let selectedProject = selectedID.flatMap { id in projectSource.first { $0.id == id } }

        var result = snapshot
        result.projects = projectSource
        result.selectedProjectID = selectedID
        result.agentRuntimes = agentRuntimes.isEmpty ? snapshot.agentRuntimes : agentRuntimes

        if let selectedProject {
            result.workspaces = result.workspaces.map { $0.attaching(selectedProject) }
            result.attempts = result.attempts.map { $0.attaching(selectedProject) }
            result.liveSessions = result.liveSessions.map { $0.attaching(selectedProject) }
        }
        result.state.runningIssueIDs = Set(result.liveSessions.map(\.issueID))
        result.state.runningSessionIDs = Set(result.liveSessions.map(\.id))
        return result
    }

    func scanProjects() async {
        let runtimes = detectAgentRuntimes()
        let enabledAgents = runtimes.filter(\.isAvailable).map(\.kind)
        let defaultAgents = enabledAgents.isEmpty ? [AIAgentKind.pi] : enabledAgents
        let existingProjectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        let discovered = await discoverProjects(defaultEnabledAgents: defaultAgents)
        var merged: [AIDiscoveredProject] = []
        merged.reserveCapacity(discovered.count)
        for project in discovered {
            var working = project
            if let stored = await stateStore.load(remote: project.gitRemote, path: project.rootPath) {
                working.trustedForAutomation = stored.trustedForAutomation
                working.enabledAgents = stored.enabledAgents
            }
            if let existing = existingProjectsByID[project.id] {
                working.trustedForAutomation = existing.trustedForAutomation
                working.enabledAgents = existing.enabledAgents
            }
            merged.append(working)
        }
        projects = merged
        agentRuntimes = runtimes

        if let selectedProjectID, projects.contains(where: { $0.id == selectedProjectID }) { return }
        selectedProjectID = projects.first?.id
    }

    func selectProject(id: String) async {
        if projects.isEmpty { await scanProjects() }
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].trustedForAutomation = true
        selectedProjectID = id
        await persistState(for: projects[index])
    }

    func setProjectAgentEnabled(projectID: String, agent: AIAgentKind, enabled: Bool) async {
        if projects.isEmpty { await scanProjects() }
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        if enabled, !projects[index].enabledAgents.contains(agent) {
            projects[index].enabledAgents.append(agent)
        } else if !enabled {
            projects[index].enabledAgents.removeAll { $0 == agent }
        }
        await persistState(for: projects[index])
    }

    func selectedProject() async -> AIDiscoveredProject? {
        if projects.isEmpty { await scanProjects() }
        let selectedID = selectedProjectID ?? projects.first?.id
        return selectedID.flatMap { id in projects.first { $0.id == id } } ?? projects.first
    }

    func projectPath(for projectID: String) async -> String? {
        if projects.isEmpty { await scanProjects() }
        return projects.first { $0.id == projectID }?.rootPath
    }

    private func persistState(for project: AIDiscoveredProject) async {
        let stored = AIProjectStoredState(
            enabledAgents: project.enabledAgents,
            trustedForAutomation: project.trustedForAutomation
        )
        await stateStore.save(remote: project.gitRemote, path: project.rootPath, state: stored)
    }

    private func detectAgentRuntimes() -> [AIAgentRuntime] {
        let kind = AIAgentKind.pi
        let path = shellCommand("command -v \(Self.shellQuotedStatic(kind.executableName))")
        let version = path.flatMap { shellCommand("\(Self.shellQuotedStatic($0)) --version") }
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
        return [AIAgentRuntime(
            kind: kind,
            executablePath: path,
            version: version,
            isAvailable: path != nil && (authConfigured || hasEnvKey),
            statusDetail: detail
        )]
    }

    private func discoverProjects(defaultEnabledAgents: [AIAgentKind]) async -> [AIDiscoveredProject] {
        let now = Date()
        var seenPaths = Set<String>()
        var candidates: [(URL, [String])] = []

        for root in discoveryRoots() {
            collectCandidates(root, depth: 0, maxDepth: 4, seenPaths: &seenPaths, candidates: &candidates)
        }

        var results: [AIDiscoveredProject] = []
        results.reserveCapacity(candidates.count)
        await withTaskGroup(of: (Int, AIDiscoveredProject).self) { group in
            for (index, candidate) in candidates.enumerated() {
                let url = candidate.0
                let markers = candidate.1
                group.addTask { [defaultEnabledAgents] in
                    let project = await Self.makeProject(at: url, markers: markers, defaultEnabledAgents: defaultEnabledAgents, now: now)
                    return (index, project)
                }
            }
            var collected: [(Int, AIDiscoveredProject)] = []
            for await pair in group { collected.append(pair) }
            collected.sort { $0.0 < $1.0 }
            results = collected.map(\.1)
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func collectCandidates(
        _ url: URL,
        depth: Int,
        maxDepth: Int,
        seenPaths: inout Set<String>,
        candidates: inout [(URL, [String])]
    ) {
        guard depth <= maxDepth else { return }
        let standardizedURL = url.standardizedFileURL
        guard seenPaths.insert(standardizedURL.path).inserted else { return }

        let markers = projectMarkers(at: standardizedURL)
        if !markers.isEmpty { candidates.append((standardizedURL, markers)) }

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: standardizedURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
            options: [.skipsPackageDescendants]
        ) else { return }

        for child in children where shouldDescend(into: child) {
            collectCandidates(child, depth: depth + 1, maxDepth: maxDepth, seenPaths: &seenPaths, candidates: &candidates)
        }
    }

    private static func makeProject(
        at url: URL,
        markers: [String],
        defaultEnabledAgents: [AIAgentKind],
        now: Date
    ) async -> AIDiscoveredProject {
        let hasGit = markers.contains(".git")
        let commands = inferredCommands(markers: markers)

        var gitRoot: String?
        var remote: String?
        var branch: String?

        if hasGit {
            let cwd = url.path
            async let rootTask: String? = runGitAsync(["rev-parse", "--show-toplevel"], cwd: cwd)
            async let remoteTask: String? = runGitAsync(["remote", "get-url", "origin"], cwd: cwd)
            async let branchTask: String? = runGitAsync(["branch", "--show-current"], cwd: cwd)
            gitRoot = await rootTask
            remote = await remoteTask
            branch = await branchTask
        }

        return AIDiscoveredProject(
            id: url.path,
            name: url.lastPathComponent,
            rootPath: url.path,
            gitRootPath: gitRoot,
            gitRemote: remote,
            currentBranch: branch,
            primaryLanguage: primaryLanguage(for: markers),
            markerSummary: markers.joined(separator: ", "),
            buildCommand: commands.build,
            testCommand: commands.test,
            trustedForAutomation: true,
            enabledAgents: defaultEnabledAgents,
            lastScannedAt: now
        )
    }

    private func projectMarkers(at url: URL) -> [String] {
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return []
        }
        let names = Set(children.map(\.lastPathComponent))
        var markers: [String] = []

        if names.contains(".git") { markers.append(".git") }
        markers.append(contentsOf: children
            .filter { $0.pathExtension == "xcodeproj" || $0.pathExtension == "xcworkspace" }
            .map(\.lastPathComponent)
            .sorted())

        for marker in ["Package.swift", "package.json", "pnpm-lock.yaml", "pyproject.toml", "Cargo.toml", "go.mod", "pom.xml", "build.gradle", "Gemfile"] {
            if names.contains(marker) { markers.append(marker) }
        }
        return markers
    }

    private func shouldDescend(into url: URL) -> Bool {
        let name = url.lastPathComponent
        guard ![".git", "build", "DerivedData", "node_modules", ".swiftpm", ".venv", "vendor"].contains(name) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return false }
        return values.isHidden != true || name == ".config"
    }

    private func discoveryRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let raw = ProcessInfo.processInfo.environment["SYMPHONY_PROJECT_ROOTS"], !raw.isEmpty {
            return raw.split(separator: ":").map {
                let path = String($0)
                let expanded = path.hasPrefix("~")
                    ? path.replacingOccurrences(of: "~", with: home.path, options: [.anchored])
                    : path
                return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            }
        }
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
        var roots = ["Programming", "Projects", "Developer", "ARC/Forge", "ARC"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        if current.path.hasPrefix(home.path) { roots.insert(current, at: 0) }
        var seen = Set<String>()
        return roots
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func primaryLanguage(for markers: [String]) -> String? {
        if markers.contains(where: { $0.hasSuffix(".xcodeproj") || $0 == "Package.swift" }) { return "Swift" }
        if markers.contains("package.json") { return "JavaScript" }
        if markers.contains("pyproject.toml") { return "Python" }
        if markers.contains("Cargo.toml") { return "Rust" }
        if markers.contains("go.mod") { return "Go" }
        if markers.contains("pom.xml") || markers.contains("build.gradle") { return "Java" }
        if markers.contains("Gemfile") { return "Ruby" }
        return nil
    }

    private static func inferredCommands(markers: [String]) -> (build: String?, test: String?) {
        if let project = markers.first(where: { $0.hasSuffix(".xcodeproj") }) {
            let scheme = String(project.dropLast(".xcodeproj".count))
            return (
                "xcodebuild -project \(shellQuotedStatic(project)) -scheme \(shellQuotedStatic(scheme)) -destination 'platform=macOS' build",
                "xcodebuild -project \(shellQuotedStatic(project)) -scheme \(shellQuotedStatic(scheme)) -destination 'platform=macOS' test"
            )
        }
        if markers.contains("Package.swift") { return ("swift build", "swift test") }
        if markers.contains("package.json") { return ("npm run build", "npm test") }
        if markers.contains("pyproject.toml") { return (nil, "pytest") }
        if markers.contains("Cargo.toml") { return ("cargo build", "cargo test") }
        if markers.contains("go.mod") { return ("go build ./...", "go test ./...") }
        return (nil, nil)
    }

    private static func shellQuotedStatic(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runGitAsync(_ arguments: [String], cwd: String) async -> String? {
        await Task.detached(priority: .utility) {
            runCommandStatic("/usr/bin/git", arguments: arguments, currentDirectoryPath: cwd)
        }.value
    }

    private static func runCommandStatic(_ executablePath: String, arguments: [String], currentDirectoryPath: String? = nil) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if let currentDirectoryPath {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
        }

        do { try process.run() } catch { return nil }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    private func shellCommand(_ command: String) -> String? {
        Self.runCommandStatic("/bin/zsh", arguments: ["-lc", command])
    }
}
