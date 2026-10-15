import SwiftUI

/// Folha "Mover para": atalhos em tiles + calendário gráfico.
/// Estilo papel — fundo cinza, cartão branco, botão preto.
struct RescheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    /// Abre grande (o calendário inteiro cabe) mas permite encolher.
    @State private var detent: PresentationDetent = .large

    private let count: Int
    private let onMove: (Date) -> Void

    init(count: Int = 1, initialDate: Date = Date(), onMove: @escaping (Date) -> Void) {
        self.count = count
        self.onMove = onMove
        _date = State(initialValue: initialDate)
    }

    private struct Shortcut: Identifiable {
        let id = UUID()
        let label: String
        let symbol: String
        let date: Date
    }

    private var shortcuts: [Shortcut] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        return [
            Shortcut(label: "Hoje", symbol: "sun.max", date: today),
            Shortcut(label: "Amanhã", symbol: "sunrise", date: tomorrow),
            Shortcut(label: "Próxima segunda", symbol: "calendar", date: Self.nextMonday(from: today)),
            Shortcut(label: "+1 semana", symbol: "arrow.turn.up.right", date: nextWeek)
        ]
    }

    private static func nextMonday(from day: Date, calendar: Calendar = .current) -> Date {
        let weekday = calendar.component(.weekday, from: day)
        let offset = (9 - weekday) % 7
        return calendar.date(byAdding: .day, value: offset == 0 ? 7 : offset, to: day) ?? day
    }

    private var subtitle: String {
        let day = Self.longFormatter.string(from: date)
        let pretty = day.prefix(1).uppercased() + day.dropFirst()
        return count > 1 ? "\(count) tarefas · \(pretty)" : pretty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    shortcutCard
                    calendarCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
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
            .safeAreaInset(edge: .bottom) { footer }
        }
        .tint(Color.primary)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    private var shortcutCard: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(shortcuts) { shortcut in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        date = shortcut.date
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: shortcut.symbol)
                            .font(.system(size: 15, weight: .medium))
                        Text(shortcut.label)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isSelected(shortcut.date) ? Color.paperInk : Color.primary)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous)
                            .fill(isSelected(shortcut.date) ? Color(uiColor: .label) : Color.paperTile)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reschedule-shortcut-" + shortcut.label)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous)
                .fill(Color.paperCard)
        )
    }

    private var calendarCard: some View {
        DatePicker("", selection: $date, displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(Color.primary)
            .environment(\.locale, Locale(identifier: "pt_BR"))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous)
                    .fill(Color.paperCard)
            )
            .accessibilityIdentifier("reschedule-calendar")
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                onMove(date)
                dismiss()
            } label: {
                Text("Mover")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.paperInk)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(
                        RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous)
                            .fill(Color(uiColor: .label))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reschedule-confirm")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.paperCanvas)
    }

    private func isSelected(_ candidate: Date) -> Bool {
        Calendar.current.isDate(candidate, inSameDayAs: date)
    }

    private static let longFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE, d 'de' MMMM"
        return formatter
    }()
}

#Preview {
    Color.paperCanvas
        .sheet(isPresented: .constant(true)) {
            RescheduleSheet { _ in }
        }
}
