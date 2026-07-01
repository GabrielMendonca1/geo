import SwiftUI

struct TaskFormFooter: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment
    @ObservedObject var viewModel: TaskFormViewModel

    var body: some View {
        HStack(spacing: 10) {
            if let saveError = viewModel.saveError {
                Label("Save failed: \(saveError)", systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let validationMessage = viewModel.validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.bordered)

            Button(viewModel.isEditing ? "Save Changes" : saveLabel) {
                Task {
                    if await viewModel.save(repository: appEnvironment.tasksRepository) {
                        dismiss()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(TaskFormStyle.accent)
            .disabled(!viewModel.canSave || viewModel.isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Palette.secondaryBackground.opacity(0.22))
    }

    private var saveLabel: String {
        switch viewModel.kind {
        case .task: return "Create Task"
        case .event: return "Create Event"
        case .habit: return "Create Habit"
        case .milestone: return "Create Milestone"
        }
    }
}
