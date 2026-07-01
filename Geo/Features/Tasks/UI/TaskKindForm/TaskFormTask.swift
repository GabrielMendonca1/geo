import SwiftUI
import GeoCore

struct TaskFormTask: View {
    @ObservedObject var viewModel: TaskFormViewModel
    let availableBlocks: [TaskBlockOption]

    var body: some View {
        VStack(spacing: 14) {
            TaskFormSectionCard(title: "Due", icon: "calendar") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Set a due date", isOn: $viewModel.hasEndDate)

                    if viewModel.hasEndDate {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Due Date")
                                    .font(.caption)
                                    .foregroundStyle(Palette.tertiaryForeground)
                                DatePicker("", selection: $viewModel.endDate, displayedComponents: .date)
                                    .datePickerStyle(.field)
                                    .labelsHidden()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            TaskChecklistCard(viewModel: viewModel, availableBlocks: availableBlocks)

            TaskFormSectionCard(title: "Priority & Status", icon: "flag") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Priority")
                            .font(.caption)
                            .foregroundStyle(Palette.tertiaryForeground)
                        Picker("Priority", selection: $viewModel.priority) {
                            ForEach(TaskPriority.allCases) { p in
                                Label(p.displayName, systemImage: p.icon).tag(p)
                            }
                        }
                        .pickerStyle(.menu)
                    }

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
            if !viewModel.hasEndDate {
                viewModel.endDate = Date()
            }
        }
    }
}
