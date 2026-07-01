import SwiftUI
import GeoCore

struct TaskFormHabit: View {
    @ObservedObject var viewModel: TaskFormViewModel
    let availableBlocks: [TaskBlockOption]

    var body: some View {
        VStack(spacing: 14) {
            TaskFormSectionCard(title: "Time of Day", icon: "clock") {
                DatePicker("", selection: $viewModel.time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field)
                    .labelsHidden()
            }

            TaskChecklistCard(viewModel: viewModel, availableBlocks: availableBlocks)

            TaskFormSectionCard(title: "Recurrence", icon: "repeat") {
                RecurrenceEditor(viewModel: viewModel)
            }

            TaskFormSectionCard(title: "Behavior", icon: "checkmark.circle") {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status")
                            .font(.caption)
                            .foregroundStyle(Palette.tertiaryForeground)
                        Picker("Status", selection: $viewModel.taskStatus) {
                            Text("Pending").tag(TaskStatus.pending)
                            Text("Completed").tag(TaskStatus.completed)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
        .onAppear {
            if viewModel.recurrenceType == .never {
                viewModel.recurrenceType = .daily
            }
        }
    }
}
