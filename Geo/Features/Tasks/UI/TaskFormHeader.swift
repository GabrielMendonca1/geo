import SwiftUI
import GeoCore

struct TaskFormHeader: View {
    @ObservedObject var viewModel: TaskFormViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 9) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(TaskFormStyle.accent.opacity(0.16))
                            Image(systemName: viewModel.kind.icon)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(TaskFormStyle.accent)
                        }
                        .frame(width: 30, height: 30)
                        Text(viewModel.isEditing ? "Edit \(viewModel.kind.displayName)" : "Create \(viewModel.kind.displayName)")
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(Palette.foreground)
                    }

                    Text(viewModel.subtitleText)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiaryForeground)
                }

                Spacer()

                Text(viewModel.headerBadgeText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(viewModel.taskStatus == .completed ? Color(nsColor: Palette.agentSuccess) : TaskFormStyle.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(
                                (viewModel.taskStatus == .completed ? Color(nsColor: Palette.agentSuccess) : TaskFormStyle.accent)
                                    .opacity(0.14)
                            )
                    )
            }

            kindPicker

            TextField(titlePlaceholder, text: $viewModel.title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Palette.background.opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Palette.border.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Palette.secondaryBackground.opacity(0.22))
        .alert(item: $viewModel.pendingKindSwitch) { pending in
            Alert(
                title: Text("Switch kind?"),
                message: Text(pending.message),
                primaryButton: .destructive(Text("Switch")) { viewModel.confirmPendingKindSwitch() },
                secondaryButton: .cancel { viewModel.cancelPendingKindSwitch() }
            )
        }
        .alert(item: $viewModel.pendingHabitTimeChoice) { _ in
            Alert(
                title: Text("Use current time?"),
                message: Text("Use the time you already entered as the habit's time-of-day, or reset to 07:00?"),
                primaryButton: .default(Text("Use current")) { viewModel.acceptHabitTimeChoice(useCurrentTime: true) },
                secondaryButton: .default(Text("Reset to 07:00")) { viewModel.acceptHabitTimeChoice(useCurrentTime: false) }
            )
        }
    }

    private var titlePlaceholder: String {
        switch viewModel.kind {
        case .task: return "What needs doing?"
        case .event: return "Event name"
        case .habit: return "Habit name"
        case .milestone: return "Milestone name"
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 6) {
            ForEach(TaskKind.allCases) { k in
                kindChip(k)
            }
        }
    }

    @ViewBuilder
    private func kindChip(_ k: TaskKind) -> some View {
        let selected = viewModel.kind == k
        Button {
            viewModel.requestKindSwitch(to: k)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: k.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(k.displayName)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? TaskFormStyle.accent.opacity(0.16) : Palette.background.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? TaskFormStyle.accent : Palette.border.opacity(0.2), lineWidth: selected ? 1.5 : 1)
            )
            .foregroundStyle(selected ? TaskFormStyle.accent : Palette.foreground)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
