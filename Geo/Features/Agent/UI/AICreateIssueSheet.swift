import AppKit
import SwiftUI

struct AICreateIssueSheet: View {
    @ObservedObject var viewModel: AIViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var title: String = ""
    @State private var selectedProjectID: String?
    @State private var runOnCreate: Bool = false
    @State private var createMore: Bool = false
    @State private var showProjectPicker: Bool = false
    @State private var modelOverride: String? = nil
    @State private var effortOverride: String? = nil
    @FocusState private var titleFocused: Bool

    @AppStorage("agent.customProjects") private var customProjectsJSON: String = "[]"
    @AppStorage("agent.lastEffortByProject") private var lastEffortJSON: String = "{}"

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        !trimmedTitle.isEmpty && selectedProjectID != nil
    }

    private var selectedProject: AgentProjectSummary? {
        guard let selectedProjectID else { return nil }
        if let p = viewModel.projects.first(where: { $0.id == selectedProjectID }) { return p }
        return customProjects.first { $0.id == selectedProjectID }
    }

    private var targetState: String {
        let s = viewModel.selectedState.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Todo" : s
    }

    private var customProjectPaths: [String] {
        guard let data = customProjectsJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    private var customProjects: [AgentProjectSummary] {
        let discoveredPaths = Set(viewModel.projects.compactMap { $0.path })
        return customProjectPaths.compactMap { path in
            if discoveredPaths.contains(path) { return nil }
            let url = URL(fileURLWithPath: path)
            return AgentProjectSummary(
                id: "custom:" + path,
                name: url.lastPathComponent,
                path: path,
                language: nil,
                branch: nil,
                enabledAgents: []
            )
        }
    }

    private var lastEffortByProject: [String: String] {
        guard let data = lastEffortJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private var currentProvider: NanoProvider {
        let raw = UserDefaults.standard.string(forKey: NanoProviderStore.defaultsKey) ?? ""
        return NanoProvider(rawValue: raw) ?? .claude
    }

    private var modelOptions: [(value: String, label: String)] {
        switch currentProvider {
        case .claude: return [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
        case .codex:  return [("gpt-5", "GPT-5"), ("gpt-5.5", "GPT-5.5")]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.2)
            content
            Divider().opacity(0.2)
            bottomBar
        }
        .frame(width: 680, height: 220)
        .background(Color(Palette.background))
        .onAppear {
            if selectedProjectID == nil {
                selectedProjectID = viewModel.selectedProject?.id
            }
            seedEffortFromMemory()
        }
        .onChange(of: selectedProjectID) { _, newID in
            seedEffortFromMemory(for: newID)
        }
        .task {
            titleFocused = true
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            projectChip
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var projectChip: some View {
        Button {
            showProjectPicker.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(selectedProject?.name ?? "Select project")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                if let branch = selectedProject?.branch, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showProjectPicker, arrowEdge: .top) {
            projectPickerPopover
        }
    }

    private var projectPickerPopover: some View {
        VStack(spacing: 0) {
            if viewModel.projects.isEmpty && customProjects.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("No projects discovered")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button {
                        viewModel.scanProjects()
                    } label: {
                        Label(viewModel.isBusy ? "Scanning…" : "Scan for projects", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(viewModel.isBusy)
                    Divider().padding(.vertical, 4)
                    addFolderButton
                }
                .padding(20)
                .frame(width: 320)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !customProjects.isEmpty {
                            sectionHeader("Custom")
                            ForEach(Array(customProjects.enumerated()), id: \.element.id) { _, project in
                                projectPickerRow(project, isCustom: true)
                                Divider().opacity(0.3)
                            }
                        }
                        if !viewModel.projects.isEmpty {
                            if !customProjects.isEmpty { sectionHeader("Discovered") }
                            ForEach(Array(viewModel.projects.enumerated()), id: \.element.id) { index, project in
                                projectPickerRow(project, isCustom: false)
                                if index < viewModel.projects.count - 1 {
                                    Divider().opacity(0.3)
                                }
                            }
                        }
                    }
                }
                .frame(width: 360)
                .frame(minHeight: 80, maxHeight: 320)

                Divider()

                HStack(spacing: 8) {
                    addFolderButton
                    Spacer()
                    Button {
                        viewModel.scanProjects()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                            Text(viewModel.isBusy ? "Scanning…" : "Rescan")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var addFolderButton: some View {
        Button {
            pickFolder()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Add folder…")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func projectPickerRow(_ project: AgentProjectSummary, isCustom: Bool) -> some View {
        let isSelected = selectedProjectID == project.id
        return Button {
            selectedProjectID = project.id
            showProjectPicker = false
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(project.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let branch = project.branch, !branch.isEmpty {
                            Text(branch)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                        }
                        Spacer(minLength: 0)
                    }
                    if let path = project.path {
                        Text(condensedPath(path))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                if isCustom {
                    Color.clear.frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if isCustom {
                Button {
                    removeCustomProject(path: project.path ?? "")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove from list")
                .padding(.trailing, 4)
            }
        }
    }

    private func condensedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Task title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .focused($titleFocused)

            propertyRow
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var propertyRow: some View {
        HStack(spacing: 6) {
            statusChip
            runChip
            runConfigChip
            Spacer(minLength: 0)
        }
    }

    private var statusChip: some View {
        chipLabel(symbol: statusSymbol(targetState), tint: statusTint(targetState), label: targetState)
            .help("Initial state — change after creating")
    }

    private var runChip: some View {
        Button {
            runOnCreate.toggle()
        } label: {
            chipLabel(
                symbol: runOnCreate ? "play.fill" : "pause",
                tint: runOnCreate ? Color.accentColor : Color.secondary,
                label: runOnCreate ? "Run on create" : "Don't run"
            )
        }
        .buttonStyle(.plain)
        .help("Toggle dispatch on create")
    }

    private var runConfigChip: some View {
        Menu {
            Picker("Model", selection: $modelOverride) {
                Text("Default").tag(String?.none)
                ForEach(modelOptions, id: \.value) { option in
                    Text(option.label).tag(String?.some(option.value))
                }
            }
            Picker("Effort", selection: $effortOverride) {
                Text("Default").tag(String?.none)
                Text("Low").tag(String?.some("low"))
                Text("Medium").tag(String?.some("medium"))
                Text("High").tag(String?.some("high"))
                Text("XHigh").tag(String?.some("xhigh"))
                Text("Max").tag(String?.some("max"))
            }
        } label: {
            chipLabel(symbol: "cpu", tint: runConfigTint, label: runConfigLabel)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model and effort for this issue")
    }

    private var runConfigLabel: String {
        let m = modelOverride?.capitalized
        let e = effortOverride?.capitalized
        switch (m, e) {
        case (nil, nil): return "Defaults"
        case let (m?, nil): return m
        case let (nil, e?): return e
        case let (m?, e?): return "\(m) · \(e)"
        }
    }

    private var runConfigTint: Color {
        (modelOverride == nil && effortOverride == nil) ? Color.secondary : Color.accentColor
    }

    private func chipLabel(symbol: String, tint: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private func statusSymbol(_ state: String) -> String {
        switch state.lowercased() {
        case "backlog": return "circle.dotted"
        case "todo": return "circle"
        case "in progress": return "circle.bottomhalf.filled"
        case "human review": return "exclamationmark.circle"
        case "done": return "checkmark.circle.fill"
        default: return "circle"
        }
    }

    private func statusTint(_ state: String) -> Color {
        switch state.lowercased() {
        case "in progress": return Color(red: 0.96, green: 0.72, blue: 0.12)
        case "human review": return Color(red: 0.95, green: 0.55, blue: 0.18)
        case "done": return Color(red: 0.22, green: 0.75, blue: 0.36)
        default: return Color.secondary
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Toggle("Create more", isOn: $createMore)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))

            Button("Create task") {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCreate)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            addCustomProject(path: url.path)
            selectedProjectID = "custom:" + url.path
            showProjectPicker = false
        }
    }

    private func addCustomProject(path: String) {
        var paths = customProjectPaths
        if !paths.contains(path) { paths.append(path) }
        writeCustomProjects(paths)
    }

    private func removeCustomProject(path: String) {
        let paths = customProjectPaths.filter { $0 != path }
        writeCustomProjects(paths)
        if selectedProjectID == "custom:" + path {
            selectedProjectID = viewModel.projects.first?.id
        }
    }

    private func writeCustomProjects(_ paths: [String]) {
        if let data = try? JSONEncoder().encode(paths),
           let s = String(data: data, encoding: .utf8) {
            customProjectsJSON = s
        }
    }

    private func seedEffortFromMemory(for projectID: String? = nil) {
        let id = projectID ?? selectedProjectID
        guard let id else { return }
        effortOverride = lastEffortByProject[id]
    }

    private func persistEffortMemory() {
        guard let projectID = selectedProjectID, let effort = effortOverride else { return }
        var dict = lastEffortByProject
        dict[projectID] = effort
        if let data = try? JSONEncoder().encode(dict),
           let s = String(data: data, encoding: .utf8) {
            lastEffortJSON = s
        }
    }

    private func resolvedProjectID() -> String? {
        guard let id = selectedProjectID else { return nil }
        if id.hasPrefix("custom:") {
            let path = String(id.dropFirst("custom:".count))
            return viewModel.projects.first { $0.path == path }?.id
        }
        return id
    }

    private func submit() {
        guard canCreate else { return }
        let openWindow = openWindow
        persistEffortMemory()
        viewModel.createIssue(
            title: trimmedTitle,
            description: "",
            projectID: resolvedProjectID(),
            runNow: runOnCreate,
            model: modelOverride,
            effort: effortOverride,
            openLinkedNode: { linkedBlockID in
                MenuActions.openBlockEditor(linkedBlockID, openWindow: openWindow)
            }
        )
        if createMore {
            title = ""
            titleFocused = true
        } else {
            dismiss()
        }
    }
}
