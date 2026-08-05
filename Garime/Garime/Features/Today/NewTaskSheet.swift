import GeoCore
import SwiftUI

private enum DraftKind: String, CaseIterable, Identifiable {
    case task
    case event
    case milestone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .task: return "tarefa"
        case .event: return "evento"
        case .milestone: return "marco"
        }
    }
}

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
        case .urgent: return "urgente"
        case .high: return "alta"
        case .medium: return "média"
        case .low: return "baixa"
        case .unset: return "nenhuma"
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
            List {
                Section {
                    TextField("", text: $title, prompt: Text("título").foregroundStyle(.tertiary))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .frame(minHeight: 44)
                }

                Section {
                    kindPicker
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }

                Section {
                    HStack(spacing: 12) {
                        Text("quando")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        DatePicker("", selection: $due)
                            .labelsHidden()
                            .environment(\.locale, Locale(identifier: "pt_BR"))
                    }
                    .frame(minHeight: 44)

                    HStack(spacing: 12) {
                        Text("prioridade")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $priority) {
                            ForEach(TaskPriority.allCases) { priority in
                                Text(Self.priorityLabel(priority)).tag(priority)
                            }
                        }
                        .labelsHidden()
                    }
                    .frame(minHeight: 44)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 44)
            .navigationTitle("nova tarefa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancelar") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    saveButton
                }
            }
        }
        .glassSheet(detents: [.large])
        .tint(Color.slateText)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: kind)
        .task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            titleFocused = true
        }
    }

    private var kindPicker: some View {
        GlassChrome {
            HStack(spacing: 8) {
                ForEach(DraftKind.allCases) { option in
                    chip(option)
                        .contentShape(Capsule())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                                kind = option
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ option: DraftKind) -> some View {
        let label = Text(option.label)
            .font(.subheadline)
            .frame(maxWidth: .infinity, minHeight: 44)

        if kind == option {
            label
                .foregroundStyle(Color.slateCanvas)
                .background(Color.slateText, in: Capsule())
        } else {
            label
                .foregroundStyle(.primary)
                .glassSurface(shape: Capsule(), interactive: true)
        }
    }

    private var saveButton: some View {
        Button {
            onCreate(TaskDraft(
                title: trimmedTitle,
                priority: priority,
                body: draftBody,
                reminders: [.atTime()]
            ))
            dismiss()
        } label: {
            Text("adicionar")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .disabled(trimmedTitle.isEmpty)
        .opacity(trimmedTitle.isEmpty ? 0.35 : 1)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: trimmedTitle.isEmpty)
    }
}
