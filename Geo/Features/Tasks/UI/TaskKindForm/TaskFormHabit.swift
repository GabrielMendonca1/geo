import SwiftUI

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

            TaskFormSectionCard(title: "Notes", icon: "text.alignleft") {
                TextField("Quick context (optional)", text: $viewModel.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            TaskFormSectionCard(title: "Block", icon: "doc.text") {
                LinkedBlockPicker(viewModel: viewModel, availableBlocks: availableBlocks)
            }
        }
        .onAppear {
            if viewModel.recurrenceType == .never {
                viewModel.recurrenceType = .daily
            }
        }
    }
}
