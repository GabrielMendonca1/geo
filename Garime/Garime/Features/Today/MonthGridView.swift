import SwiftUI

enum CalendarMode {
    case week
    case month
}

enum MonthGrid {
    static var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal
    }

    static let weekdayLabels = ["seg", "ter", "qua", "qui", "sex", "sab", "dom"]

    static func days(for month: Date) -> [Date] {
        let cal = calendar
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let weekday = cal.component(.weekday, from: startOfMonth)
        let offset = (weekday - cal.firstWeekday + 7) % 7
        let gridStart = cal.date(byAdding: .day, value: -offset, to: startOfMonth) ?? startOfMonth
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    static func title(for month: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: month).lowercased()
    }
}

enum DayDot {
    static func color(for date: Date, hasItems: Bool) -> Color? {
        let cal = MonthGrid.calendar
        if cal.isDateInToday(date) { return .red }
        if cal.startOfDay(for: date) < cal.startOfDay(for: Date()) { return .slateTextFaint }
        return hasItems ? .blue : nil
    }
}

struct MonthGridView: View {
    @Binding var selectedDate: Date
    let displayedMonth: Date
    let hasItemsByDate: [Date: Bool]
    let onShiftMonth: (Int) -> Void
    let onSelect: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        VStack(spacing: 10) {
            header

            HStack(spacing: 6) {
                ForEach(MonthGrid.weekdayLabels, id: \.self) { label in
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(MonthGrid.days(for: displayedMonth), id: \.self) { date in
                    cell(for: date)
                }
            }
            .id(displayedMonth)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if value.translation.width < -40 {
                        onShiftMonth(1)
                    } else if value.translation.width > 40 {
                        onShiftMonth(-1)
                    }
                }
        )
    }

    private var header: some View {
        HStack {
            navButton("chevron.left") { onShiftMonth(-1) }

            Spacer()

            Text(MonthGrid.title(for: displayedMonth))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .contentTransition(.opacity)

            Spacer()

            navButton("chevron.right") { onShiftMonth(1) }
        }
    }

    private func navButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSurface(shape: Circle(), interactive: true)
    }

    private func cell(for date: Date) -> some View {
        let cal = MonthGrid.calendar
        let dayNum = cal.component(.day, from: date)
        let isSelected = cal.isDate(selectedDate, inSameDayAs: date)
        let inMonth = cal.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let hasItems = hasItemsByDate[cal.startOfDay(for: date)] ?? false
        let isToday = cal.isDateInToday(date)

        return ZStack {
            RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous)
                .fill(.primary.opacity(isSelected ? 0.14 : 0))

            Text("\(dayNum)")
                .font(.subheadline)
                .fontWeight(isToday ? .semibold : .regular)
                .foregroundStyle(inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))

            if let dotColor = DayDot.color(for: date, hasItems: hasItems) {
                VStack {
                    Spacer()
                    Circle()
                        .fill(dotColor)
                        .frame(width: 4, height: 4)
                        .padding(.bottom, 4)
                }
                .opacity(inMonth ? 1 : 0.35)
            }
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(date)
        }
    }
}
