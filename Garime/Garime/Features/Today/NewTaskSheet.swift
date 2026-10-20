import GeoCore
import SwiftUI

private enum DraftKind: String, CaseIterable, Identifiable {
    case task
    case event
    case milestone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .task: return "Tarefa"
        case .event: return "Evento"
        case .milestone: return "Marco"
        }
    }
}

/// Folha de nova tarefa no estilo papel: campo grande em tile,
/// linhas de cartão branco para data/hora e chips para tipo/prioridade.
struct NewTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var title = ""
    @State private var due = Date()
    @State private var kind: DraftKind = .task
    @State private var priority: TaskPriority = .unset
    let onCreate: (TaskDraft) -> Void

    static func priorityLabel(_ priority: TaskPriority) -> String {
        switch priority {
        case .urgent: return "Urgente"
        case .high: return "Alta"
        case .medium: return "Média"
        case .low: return "Baixa"
        case .unset: return "Nenhuma"
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draftBody: TaskBody {
        switch kind {
        case .task:
            return .task(due: due, estimatedMinutes: nil)
        case .event:
            return .event(start: due, end: due.addingTimeInterval(3600), externalEKEventID: nil)
        case .milestone:
            return .milestone(target: due)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    scheduleCard
                    priorityCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color.paperCanvas)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Nova tarefa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .foregroundStyle(Color.primary)
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
        .tint(Color.primary)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: kind)
        .task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            titleFocused = true
        }
    }

    // MARK: - Blocos

    private var headerCard: some View {
        VStack(spacing: 12) {
            TextField("", text: $title, prompt: Text("Título").foregroundStyle(.tertiary))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.primary)
                .focused($titleFocused)
                .submitLabel(.done)
                .padding(.horizontal, 14)
                .frame(minHeight: 64)
                .background(
                    RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous)
                        .fill(Color.paperTile)
                )
                .accessibilityIdentifier("new-task-title")

            HStack(spacing: 8) {
                ForEach(DraftKind.allCases) { option in
                    chip(option.label, selected: kind == option) {
                        kind = option
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous)
                .fill(Color.paperCard)
        )
    }

    private var scheduleCard: some View {
        VStack(spacing: 0) {
            row(label: kind == .event ? "Início" : "Quando") {
                DatePicker("", selection: $due, displayedComponents: [.date])
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "pt_BR"))
            }
            divider
            row(label: "Hora") {
                DatePicker("", selection: $due, displayedComponents: [.hourAndMinute])
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "pt_BR"))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous)
                .fill(Color.paperCard)
        )
    }

    private var priorityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prioridade")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(TaskPriority.allCases) { option in
                    chip(Self.priorityLabel(option), selected: priority == option) {
                        priority = option
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous)
                .fill(Color.paperCard)
        )
    }

    private var footer: some View {
        Button {
            onCreate(TaskDraft(
                title: trimmedTitle,
                priority: priority,
                body: draftBody,
                reminders: [.atTime()]
            ))
            dismiss()
        } label: {
            Text("Adicionar")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.paperInk)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(
                    RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous)
                        .fill(Color(uiColor: .label))
                )
        }
        .buttonStyle(.plain)
        .disabled(trimmedTitle.isEmpty)
        .opacity(trimmedTitle.isEmpty ? 0.35 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: trimmedTitle.isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.paperCanvas)
        .accessibilityIdentifier("new-task-add")
    }

    // MARK: - Peças

    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 16)
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { action() }
        } label: {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? Color.paperInk : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous)
                        .fill(selected ? Color(uiColor: .label) : Color.paperTile)
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Color.paperCanvas
        .sheet(isPresented: .constant(true)) {
            NewTaskSheet { _ in }
        }
}
