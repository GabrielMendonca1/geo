import GeoCore
import SwiftUI

/// Mover uma tarefa de dia: atalhos em tiles + calendário, no visual paper.
struct CalendarRescheduleSheet: View {
    let task: TaskItem
    let onMove: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(task: TaskItem, onMove: @escaping (Date) -> Void) {
        self.task = task
        self.onMove = onMove
        _date = State(initialValue: task.anchorDate)
    }

    private struct Shortcut: Identifiable {
        let id = UUID()
        let label: String
        let date: Date
    }

    private var shortcuts: [Shortcut] {
        let cal = CalGrid.calendar
        let today = cal.startOfDay(for: Date())
        var result: [Shortcut] = [Shortcut(label: "Hoje", date: today)]
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: today) {
            result.append(Shortcut(label: "Amanhã", date: tomorrow))
        }
        if let monday = nextMonday(after: today, calendar: cal) {
            result.append(Shortcut(label: "Próxima segunda", date: monday))
        }
        if let week = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: date)) {
            result.append(Shortcut(label: "+1 semana", date: week))
        }
        return result
    }

    private func nextMonday(after day: Date, calendar: Calendar) -> Date? {
        let weekday = calendar.component(.weekday, from: day)
        let delta = (9 - weekday) % 7
        return calendar.date(byAdding: .day, value: delta == 0 ? 7 : delta, to: day)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(task.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(
                            Color.paperCard,
                            in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous)
                        )

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(shortcuts) { shortcut in
                            shortcutTile(shortcut)
                        }
                    }

                    DatePicker("Data", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .tint(Color.primary)
                        .environment(\.locale, Locale(identifier: "pt_BR"))
                        .labelsHidden()
                        .padding(8)
                        .background(
                            Color.paperCard,
                            in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous)
                        )

                    Button {
                        onMove(date)
                        dismiss()
                    } label: {
                        Text("Mover")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.paperInk)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(
                                Color.paperFilled,
                                in: RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("calendar-reschedule-confirm")
                }
                .padding(16)
            }
            .background(Color.paperCanvas)
            .navigationTitle("Mover para")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .foregroundStyle(Color.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func shortcutTile(_ shortcut: Shortcut) -> some View {
        let selected = CalGrid.calendar.isDate(date, inSameDayAs: shortcut.date)
        return Button {
            date = shortcut.date
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.label)
                    .font(.system(size: 15, weight: .semibold))
                Text(CalendarRescheduleSheet.shortDate(shortcut.date))
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.paperInk.opacity(0.7) : Color.secondary)
            }
            .foregroundStyle(selected ? Color.paperInk : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                selected ? Color.paperFilled : Color.paperTile,
                in: RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date).replacingOccurrences(of: ".", with: "")
    }
}

extension Color {
    /// Preto sólido para preenchimentos: `Color.primary` como ShapeStyle herda o
    /// `foregroundStyle` do ambiente e clareia dentro de botões invertidos.
    static let paperFilled = Color(uiColor: .label)
}
