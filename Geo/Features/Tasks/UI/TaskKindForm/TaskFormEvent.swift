import SwiftUI
import GeoCore

struct TaskFormEvent: View {
    @ObservedObject var viewModel: TaskFormViewModel
    let availableBlocks: [TaskBlockOption]

    @State private var isRepeatExpanded = false

    var body: some View {
        VStack(spacing: 14) {
            TaskFormSectionCard(title: "When", icon: "calendar.badge.clock") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("All-day", isOn: $viewModel.isAllDay)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Start Date")
                                .font(.caption)
                                .foregroundStyle(Palette.tertiaryForeground)
                            DatePicker("", selection: $viewModel.date, displayedComponents: .date)
                                .datePickerStyle(.field)
                                .labelsHidden()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !viewModel.isAllDay {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Start Time")
                                    .font(.caption)
                                    .foregroundStyle(Palette.tertiaryForeground)
                                DatePicker("", selection: $viewModel.time, displayedComponents: .hourAndMinute)
                                    .datePickerStyle(.field)
                                    .labelsHidden()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Toggle("Set end", isOn: $viewModel.hasEndDate)

                    if viewModel.hasEndDate {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("End Date")
                                    .font(.caption)
                                    .foregroundStyle(Palette.tertiaryForeground)
                                DatePicker("", selection: $viewModel.endDate, displayedComponents: .date)
                                    .datePickerStyle(.field)
                                    .labelsHidden()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if !viewModel.isAllDay {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("End Time")
                                        .font(.caption)
                                        .foregroundStyle(Palette.tertiaryForeground)
                                    DatePicker("", selection: $viewModel.endTime, displayedComponents: .hourAndMinute)
                                        .datePickerStyle(.field)
                                        .labelsHidden()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }

            TaskChecklistCard(viewModel: viewModel, availableBlocks: availableBlocks)

            TaskFormCollapsibleCard(
                title: "Repeat",
                icon: "repeat",
                summary: repeatSummary,
                isExpanded: $isRepeatExpanded
            ) {
                RecurrenceEditor(viewModel: viewModel)
            }

            TaskFormSectionCard(title: "Status", icon: "checkmark.circle") {
                Picker("Status", selection: $viewModel.taskStatus) {
                    Text("Pending").tag(TaskStatus.pending)
                    Text("Completed").tag(TaskStatus.completed)
                }
                .pickerStyle(.segmented)
            }
        }
        .onChange(of: viewModel.isAllDay) { _, allDay in
            if allDay {
                let calendar = Calendar.current
                viewModel.time = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: viewModel.date) ?? viewModel.date
                viewModel.endTime = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: viewModel.endDate) ?? viewModel.endDate
            }
        }
        .onAppear {
            if !viewModel.hasEndDate {
                viewModel.hasEndDate = true
                viewModel.endDate = viewModel.date
                viewModel.endTime = viewModel.time.addingTimeInterval(3600)
            }
        }
    }

    private var repeatSummary: String {
        switch viewModel.recurrenceType {
        case .never: return "Off"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .biweekly: return "Biweekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .custom:
            return "Every \(viewModel.customInterval) \(viewModel.customInterval == 1 ? viewModel.customFrequency.rawValue : viewModel.customFrequency.plural)"
        }
    }
}

struct RecurrenceEditor: View {
    @ObservedObject var viewModel: TaskFormViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Frequency", selection: $viewModel.recurrenceType) {
                Text("Never").tag(RecurrenceRule.RuleType.never)
                Text("Daily").tag(RecurrenceRule.RuleType.daily)
                Text("Weekdays").tag(RecurrenceRule.RuleType.weekdays)
                Text("Weekly").tag(RecurrenceRule.RuleType.weekly)
                Text("Every 2 weeks").tag(RecurrenceRule.RuleType.biweekly)
                Text("Monthly").tag(RecurrenceRule.RuleType.monthly)
                Text("Yearly").tag(RecurrenceRule.RuleType.yearly)
                Text("Custom").tag(RecurrenceRule.RuleType.custom)
            }
            .pickerStyle(.menu)

            if viewModel.recurrenceType == .custom {
                HStack(spacing: 12) {
                    Stepper("Every \(viewModel.customInterval)", value: $viewModel.customInterval, in: 1...365)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("Unit", selection: $viewModel.customFrequency) {
                        ForEach(RecurrenceFrequency.allCases) { freq in
                            Text(viewModel.customInterval == 1 ? freq.rawValue : freq.plural).tag(freq)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
            }

            if showsWeekdayPicker {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On days")
                        .font(.caption)
                        .foregroundStyle(Palette.tertiaryForeground)
                    HStack(spacing: 4) {
                        ForEach(TaskFormWeekday.options, id: \.value) { day in
                            Toggle(isOn: Binding(
                                get: { viewModel.selectedWeekdays.contains(day.value) },
                                set: { on in
                                    if on {
                                        viewModel.selectedWeekdays.insert(day.value)
                                    } else if viewModel.selectedWeekdays.count > 1 {
                                        viewModel.selectedWeekdays.remove(day.value)
                                    }
                                }
                            )) {
                                Text(day.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(minWidth: 32)
                            }
                            .toggleStyle(.button)
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            if viewModel.recurrenceType != .never {
                Toggle("Set end date", isOn: $viewModel.hasRecurrenceEndDate)

                if viewModel.hasRecurrenceEndDate {
                    DatePicker("Ends on", selection: $viewModel.recurrenceEndDate, displayedComponents: .date)
                        .datePickerStyle(.field)
                }
            }
        }
    }

    private var showsWeekdayPicker: Bool {
        switch viewModel.recurrenceType {
        case .weekly, .biweekly: return true
        case .custom: return viewModel.customFrequency == .weekly
        default: return false
        }
    }
}
