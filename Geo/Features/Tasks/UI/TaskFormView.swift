import SwiftUI
import GeoCore

enum TaskFormStyle {
    static let accent = GeoStyle.Colors.geoBlueDark
    static let cardRadius: CGFloat = 14
    static let cardFill = Palette.secondaryBackground.opacity(0.55)
    static let cardStroke = Palette.border.opacity(0.35)
}

struct TaskFormView: View {

    let editingTask: TaskItem?
    let availableBlocks: [TaskBlockOption]
    let preFillBlockId: String?
    let preFillDate: Date?

    @StateObject private var viewModel = TaskFormViewModel()

    init(
        editingTask: TaskItem? = nil,
        availableBlocks: [TaskBlockOption] = [],
        preFillBlockId: String? = nil,
        preFillDate: Date? = nil
    ) {
        self.editingTask = editingTask
        self.availableBlocks = availableBlocks
        self.preFillBlockId = preFillBlockId
        self.preFillDate = preFillDate
    }

    var body: some View {
        VStack(spacing: 0) {
            TaskFormHeader(viewModel: viewModel)
            Divider()
            ScrollView {
                Group {
                    switch viewModel.kind {
                    case .task:
                        TaskFormTask(viewModel: viewModel, availableBlocks: availableBlocks)
                    case .event:
                        TaskFormEvent(viewModel: viewModel, availableBlocks: availableBlocks)
                    case .habit:
                        TaskFormHabit(viewModel: viewModel, availableBlocks: availableBlocks)
                    case .milestone:
                        TaskFormMilestone(viewModel: viewModel, availableBlocks: availableBlocks)
                    }
                }
                .padding(18)
            }
            Divider()
            TaskFormFooter(viewModel: viewModel)
        }
        .frame(width: 560, height: 730)
        .background(
            LinearGradient(
                colors: [
                    Palette.background,
                    Palette.secondaryBackground.opacity(0.3)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .task {
            viewModel.loadEditingTaskIfNeeded(editingTask)
            if editingTask == nil, let preFillBlockId, viewModel.linkedBlockId == nil {
                viewModel.linkedBlockId = preFillBlockId
            }
            if editingTask == nil, let preFillDate {
                viewModel.applyPrefillDate(preFillDate)
            }
        }
        .onChange(of: viewModel.customInterval) { _, newValue in
            if newValue < 1 {
                viewModel.customInterval = 1
            }
        }
    }
}

struct TaskFormSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(TaskFormStyle.accent.opacity(0.16))
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TaskFormStyle.accent)
            }
            .frame(width: 22, height: 22)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(Palette.tertiaryForeground)
        }
    }
}

struct TaskFormSectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TaskFormSectionHeader(title: title, icon: icon)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TaskFormStyle.cardRadius)
                .fill(TaskFormStyle.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TaskFormStyle.cardRadius)
                .stroke(TaskFormStyle.cardStroke, lineWidth: 1)
        )
    }
}

struct TaskFormCollapsibleCard<Content: View>: View {
    let title: String
    let icon: String
    let summary: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    TaskFormSectionHeader(title: title, icon: icon)
                    if !isExpanded {
                        Text(summary)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.tertiaryForeground)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.tertiaryForeground)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TaskFormStyle.cardRadius)
                .fill(TaskFormStyle.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TaskFormStyle.cardRadius)
                .stroke(TaskFormStyle.cardStroke, lineWidth: 1)
        )
    }
}

struct TaskChecklistCard: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var viewModel: TaskFormViewModel
    let availableBlocks: [TaskBlockOption]

    @State private var checkboxes: [BlockCheckbox] = []
    @State private var linkedBlockTitle: String?
    @State private var newItemText: String = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @FocusState private var newItemFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TaskFormSectionHeader(title: "Checklist", icon: "checklist")
                if !checkboxes.isEmpty {
                    Text("\(checkboxes.filter(\.checked).count)/\(checkboxes.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TaskFormStyle.accent)
                }
                Spacer()
                if viewModel.linkedBlockId != nil {
                    blockMenu
                }
            }

            if viewModel.linkedBlockId != nil {
                linkedContent
            } else {
                emptyContent
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TaskFormStyle.cardRadius)
                .fill(TaskFormStyle.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TaskFormStyle.cardRadius)
                .stroke(viewModel.linkedBlockId == nil ? TaskFormStyle.cardStroke : TaskFormStyle.accent.opacity(0.35), lineWidth: 1)
        )
        .task(id: viewModel.linkedBlockId) {
            await refresh()
        }
    }

    @ViewBuilder
    private var linkedContent: some View {
        Button {
            openLinkedBlock()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TaskFormStyle.accent)
                Text(linkedBlockTitle ?? "Linked block")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(Palette.foreground)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.tertiaryForeground)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Palette.background.opacity(0.7))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()

        if checkboxes.isEmpty {
            Text("No items yet — add the first step below.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiaryForeground)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(checkboxes, id: \.lineNumber) { checkbox in
                    checkboxRow(checkbox)
                }
            }
        }

        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TaskFormStyle.accent)
            TextField("Add checklist item", text: $newItemText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($newItemFocused)
                .onSubmit { addItem() }
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.background.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Palette.border.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var emptyContent: some View {
        Text("No checklist yet. Create a block named after this task to track its steps.")
            .font(.system(size: 11))
            .foregroundStyle(Palette.tertiaryForeground)

        HStack(spacing: 8) {
            Button {
                Task { await createWorkspaceBlock() }
            } label: {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                    }
                    Text("Create checklist block")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(TaskFormStyle.accent)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .pointingHandCursor()

            Menu {
                ForEach(sortedBlocks) { block in
                    Button(block.title) { viewModel.linkedBlockId = block.id }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Link existing")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Palette.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Palette.background.opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Palette.border.opacity(0.3), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var blockMenu: some View {
        Menu {
            Button("Open in editor") { openLinkedBlock() }
            Divider()
            Menu("Change block") {
                ForEach(sortedBlocks) { block in
                    Button(block.title) { viewModel.linkedBlockId = block.id }
                }
            }
            Button("Unlink", role: .destructive) { viewModel.linkedBlockId = nil }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.tertiaryForeground)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func checkboxRow(_ checkbox: BlockCheckbox) -> some View {
        Button {
            toggle(checkbox)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: checkbox.checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(checkbox.checked ? TaskFormStyle.accent : Palette.tertiaryForeground)
                Text(checkbox.text)
                    .font(.system(size: 12))
                    .foregroundStyle(checkbox.checked ? Palette.tertiaryForeground : Palette.foreground.opacity(0.92))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var sortedBlocks: [TaskBlockOption] {
        availableBlocks.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func openLinkedBlock() {
        guard let blockId = viewModel.linkedBlockId else { return }
        openWindow(id: "editor", value: blockId)
    }

    private func refresh() async {
        guard let blockId = viewModel.linkedBlockId else {
            checkboxes = []
            linkedBlockTitle = nil
            return
        }
        let repository = appEnvironment.blocksRepository
        checkboxes = await repository.checkboxes(in: blockId)
        if let match = availableBlocks.first(where: { $0.id == blockId }) {
            linkedBlockTitle = match.title
        } else if let block = try? await repository.get(id: blockId) {
            linkedBlockTitle = block.displayTitle
        }
    }

    private func toggle(_ checkbox: BlockCheckbox) {
        guard let blockId = viewModel.linkedBlockId else { return }
        if let idx = checkboxes.firstIndex(where: { $0.lineNumber == checkbox.lineNumber }) {
            checkboxes[idx] = BlockCheckbox(text: checkbox.text, checked: !checkbox.checked, lineNumber: checkbox.lineNumber)
        }
        Task {
            do {
                try await appEnvironment.blocksRepository.toggleCheckbox(in: blockId, lineNumber: checkbox.lineNumber)
                errorMessage = nil
            } catch {
                errorMessage = "Could not update item: \(error.localizedDescription)"
            }
            await refresh()
        }
    }

    private func addItem() {
        let text = newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let blockId = viewModel.linkedBlockId, !isBusy else { return }
        newItemText = ""
        Task {
            isBusy = true
            do {
                let repository = appEnvironment.blocksRepository
                guard let block = try await repository.get(id: blockId) else {
                    throw RepositoryError.notFound
                }
                var markdown = block.markdown
                if !markdown.isEmpty, !markdown.hasSuffix("\n") {
                    markdown += "\n"
                }
                markdown += "- [ ] \(text)\n"
                try await repository.update(id: blockId, markdown: markdown)
                errorMessage = nil
            } catch {
                errorMessage = "Could not add item: \(error.localizedDescription)"
            }
            await refresh()
            isBusy = false
            newItemFocused = true
        }
    }

    private func createWorkspaceBlock() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let title = viewModel.trimmedTitle.isEmpty ? "New Task" : viewModel.trimmedTitle
        do {
            let block = try await appEnvironment.blocksRepository.create(title: title, markdown: "")
            viewModel.linkedBlockId = block.id
            errorMessage = nil
            newItemFocused = true
        } catch {
            errorMessage = "Could not create block: \(error.localizedDescription)"
        }
    }
}

enum TaskFormWeekday {
    static let options: [(label: String, value: Int)] = [
        ("Sun", 1), ("Mon", 2), ("Tue", 3), ("Wed", 4),
        ("Thu", 5), ("Fri", 6), ("Sat", 7)
    ]
}
