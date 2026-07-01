import SwiftUI
import GeoCore

struct TaskFormMilestone: View {
    @ObservedObject var viewModel: TaskFormViewModel
    let availableBlocks: [TaskBlockOption]

    var body: some View {
        VStack(spacing: 14) {
            TaskFormSectionCard(title: "Target Date", icon: "flag.fill") {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("", selection: $viewModel.date, displayedComponents: .date)
                        .datePickerStyle(.field)
                        .labelsHidden()

                    if let countdownText {
                        Text(countdownText)
                            .font(.caption)
                            .foregroundStyle(TaskFormStyle.accent)
                    }
                }
            }

            TaskChecklistCard(viewModel: viewModel, availableBlocks: availableBlocks)

            TaskFormSectionCard(title: "Priority & Status", icon: "exclamationmark.circle") {
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
            viewModel.hasEndDate = false
            viewModel.recurrenceType = .never
        }
    }

    private var countdownText: String? {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: viewModel.date)
        guard let days = calendar.dateComponents([.day], from: now, to: target).day else { return nil }
        if days == 0 { return "Today" }
        if days > 0 { return "\(days) day\(days == 1 ? "" : "s") remaining" }
        return "\(-days) day\(days == -1 ? "" : "s") overdue"
    }
}
