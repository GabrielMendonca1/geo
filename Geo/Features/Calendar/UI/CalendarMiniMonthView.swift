import SwiftUI

struct CalendarMiniMonthView: View {
    @Binding var currentMonth: Date
    @State private var displayedMonth: Date

    private let calendar = Calendar.current

    init(currentMonth: Binding<Date>) {
        _currentMonth = currentMonth
        _displayedMonth = State(initialValue: currentMonth.wrappedValue)
    }

    private var displayMonth: Date {
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        return calendar.date(from: comps) ?? displayedMonth
    }

    private static var monthFormatter: DateFormatter { DateFormatters.monthYear }

    private var monthTitle: String {
        Self.monthFormatter.string(from: displayMonth)
    }

    private var weeks: [[Date?]] {
        let comps = calendar.dateComponents([.year, .month], from: displayMonth)
        guard let firstOfMonth = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let offset = (firstWeekday - calendar.firstWeekday + 7) % 7

        var days: [Date?] = Array(repeating: nil, count: offset)
        for day in range {
            var dc = comps
            dc.day = day
            days.append(calendar.date(from: dc))
        }
        while days.count % 7 != 0 {
            days.append(nil)
        }

        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<$0+7]) }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...]) + Array(symbols[..<first])
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayMonth) ?? displayedMonth
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.foreground.opacity(0.6))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Spacer()

                Text(monthTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.foreground)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayMonth) ?? displayedMonth
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.foreground.opacity(0.6))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(weeks.indices, id: \.self) { weekIndex in
                    ForEach(0..<7, id: \.self) { dayIndex in
                        let date = weeks[weekIndex][dayIndex]
                        miniDayCell(date: date)
                    }
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func miniDayCell(date: Date?) -> some View {
        if let date {
            let isToday = calendar.isDateInToday(date)

            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 11, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Palette.accent : Palette.foreground)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(isToday ? Palette.accent.opacity(0.15) : Color.clear)
                )
        } else {
            Color.clear
                .frame(width: 22, height: 22)
        }
    }
}
