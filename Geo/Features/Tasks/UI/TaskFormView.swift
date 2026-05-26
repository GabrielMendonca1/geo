import SwiftUI

struct TaskFormView: View {

    let editingTask: TaskItem?
    let availableBlocks: [TaskBlockOption]
    let preFillBlockId: String?

    @StateObject private var viewModel = TaskFormViewModel()

    init(
        editingTask: TaskItem? = nil,
        availableBlocks: [TaskBlockOption] = [],
        preFillBlockId: String? = nil
    ) {
        self.editingTask = editingTask
        self.availableBlocks = availableBlocks
        self.preFillBlockId = preFillBlockId
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
                    Palette.secondaryBackground.opacity(0.2)
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
        }
        .onChange(of: viewModel.customInterval) { _, newValue in
            if newValue < 1 {
                viewModel.customInterval = 1
            }
        }
    }
}

struct TaskFormSectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Palette.background.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Palette.border.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 1)
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
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.foreground)
                    if !isExpanded {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.tertiaryForeground)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.tertiaryForeground)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Palette.background.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Palette.border.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 1)
    }
}

struct LinkedBlockPicker: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @ObservedObject var viewModel: TaskFormViewModel
    let availableBlocks: [TaskBlockOption]

    @State private var search: String = ""
    @State private var creatingBlock = false
    @State private var creationError: String?
    @State private var inlineEditorBlockId: String?
    @State private var inlineEditorMarkdown: String = ""
    @State private var inlineEditorTitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Linked Block")
                .font(.caption)
                .foregroundStyle(Palette.tertiaryForeground)

            TextField("Search blocks", text: $search)
                .textFieldStyle(.roundedBorder)

            Menu {
                Button("None") { viewModel.linkedBlockId = nil }
                Divider()
                Button {
                    Task { await createInlineBlock() }
                } label: {
                    Label("Create new block", systemImage: "plus.square")
                }
                if !filteredBlocks.isEmpty {
                    Divider()
                    ForEach(filteredBlocks) { block in
                        Button(block.title) { viewModel.linkedBlockId = block.id }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundStyle(Palette.accent)
                    Text(currentLabel)
                        .foregroundStyle(Palette.foreground)
                    Spacer()
                    if creatingBlock {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.tertiaryForeground)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Palette.background.opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Palette.border.opacity(0.2), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            if let creationError {
                Label(creationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .sheet(item: Binding(
            get: { inlineEditorBlockId.map { InlineBlockEditorIdentifier(id: $0) } },
            set: { newValue in
                if newValue == nil { inlineEditorBlockId = nil }
            }
        )) { ident in
            InlineBlockEditorSheet(
                blockId: ident.id,
                title: inlineEditorTitle,
                markdown: $inlineEditorMarkdown,
                onSave: { saveInlineBlock(id: ident.id) },
                onDismiss: { inlineEditorBlockId = nil }
            )
        }
    }

    private var filteredBlocks: [TaskBlockOption] {
        let sorted = availableBlocks.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        if search.isEmpty { return sorted }
        return sorted.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var currentLabel: String {
        guard let id = viewModel.linkedBlockId else { return "None" }
        if let match = availableBlocks.first(where: { $0.id == id }) {
            return match.title
        }
        return "Linked block"
    }

    private func createInlineBlock() async {
        creatingBlock = true
        creationError = nil
        defer { creatingBlock = false }

        let baseTitle = viewModel.trimmedTitle.isEmpty ? "New Block" : viewModel.trimmedTitle
        do {
            let block = try await appEnvironment.blocksRepository.create(title: baseTitle, markdown: "")
            viewModel.linkedBlockId = block.id
            inlineEditorTitle = block.title.isEmpty ? baseTitle : block.title
            inlineEditorMarkdown = block.markdown
            inlineEditorBlockId = block.id
        } catch {
            creationError = "Could not create block: \(error.localizedDescription)"
        }
    }

    private func saveInlineBlock(id: String) {
        let markdown = inlineEditorMarkdown
        Task {
            do {
                try await appEnvironment.blocksRepository.update(id: id, markdown: markdown)
            } catch {
                await MainActor.run {
                    creationError = "Could not save block content: \(error.localizedDescription)"
                }
            }
        }
        inlineEditorBlockId = nil
    }
}

private struct InlineBlockEditorIdentifier: Identifiable {
    let id: String
}

private struct InlineBlockEditorSheet: View {
    let blockId: String
    let title: String
    @Binding var markdown: String
    let onSave: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(Palette.accent)
                Text(title.isEmpty ? "New Block" : title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Palette.secondaryBackground.opacity(0.22))

            Divider()

            TextEditor(text: $markdown)
                .font(.system(size: 13))
                .padding(12)

            Divider()

            HStack {
                Text("Markdown supported")
                    .font(.caption)
                    .foregroundStyle(Palette.tertiaryForeground)
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Palette.secondaryBackground.opacity(0.22))
        }
        .frame(width: 480, height: 380)
        .background(Palette.background)
    }
}

struct RecurringReminderRow: View {
    @Binding var reminder: RecurringReminder
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Stepper("Every \(reminder.interval)", value: $reminder.interval, in: 1...365)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Unit", selection: $reminder.frequency) {
                    ForEach(RecurrenceFrequency.allCases) { freq in
                        Text(reminder.interval == 1 ? freq.rawValue : freq.plural).tag(freq)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            DatePicker("Time", selection: $reminder.timeOfDay, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.secondaryBackground.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Palette.border.opacity(0.16), lineWidth: 1)
        )
        .onChange(of: reminder.interval) { _, newValue in
            if newValue < 1 {
                reminder.interval = 1
            }
        }
    }
}

enum TaskFormWeekday {
    static let options: [(label: String, value: Int)] = [
        ("Sun", 1), ("Mon", 2), ("Tue", 3), ("Wed", 4),
        ("Thu", 5), ("Fri", 6), ("Sat", 7)
    ]
}
