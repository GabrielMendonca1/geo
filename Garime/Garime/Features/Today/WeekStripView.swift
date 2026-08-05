import SwiftUI

struct WeekStripView: View {
    @Binding var selectedDate: Date
    let hasItemsByDate: [Date: Bool]

    @State private var visibleWeek: Date?

    private static let dayLabels = ["seg", "ter", "qua", "qui", "sex", "sab", "dom"]

    private static func startOfWeek(for date: Date) -> Date {
        let cal = MonthGrid.calendar
        return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) ?? date
    }

    private static let weeks: [Date] = {
        let cal = MonthGrid.calendar
        let base = startOfWeek(for: Date())
        return (-52...52).compactMap { cal.date(byAdding: .weekOfYear, value: $0, to: base) }
    }()

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Self.weeks, id: \.self) { week in
                    week7(week)
                        .containerRelativeFrame(.horizontal)
                        .id(week)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleWeek)
        .frame(height: 76)
        .padding(.vertical, 12)
        .onAppear {
            if visibleWeek == nil { visibleWeek = Self.startOfWeek(for: selectedDate) }
        }
        .onChange(of: visibleWeek) { _, newValue in
            guard let week = newValue else { return }
            let cal = MonthGrid.calendar
            let offset = cal.dateComponents(
                [.day],
                from: Self.startOfWeek(for: selectedDate),
                to: cal.startOfDay(for: selectedDate)
            ).day ?? 0
            guard let target = cal.date(byAdding: .day, value: offset, to: week),
                  !cal.isDate(target, inSameDayAs: selectedDate)
            else { return }
            selectedDate = target
        }
        .onChange(of: selectedDate) { _, newValue in
            let week = Self.startOfWeek(for: newValue)
            guard visibleWeek != week else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                visibleWeek = week
            }
        }
    }

    private func week7(_ week: Date) -> some View {
        let cal = MonthGrid.calendar
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: week) }

        return HStack(spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.element) { index, date in
                let dayNum = cal.component(.day, from: date)
                let isSelected = cal.isDate(selectedDate, inSameDayAs: date)
                let hasItems = hasItemsByDate[cal.startOfDay(for: date)] ?? false

                VStack(spacing: 4) {
                    Text(Self.dayLabels[index])
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    ZStack {
                        RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous)
                            .fill(.primary.opacity(isSelected ? 0.14 : 0))

                        Text("\(dayNum)")
                            .font(.subheadline)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundStyle(.primary)

                        if let dotColor = DayDot.color(for: date, hasItems: hasItems) {
                            VStack {
                                Spacer()
                                Circle()
                                    .fill(dotColor)
                                    .frame(width: 4, height: 4)
                                    .padding(.bottom, 4)
                            }
                        }
                    }
                    .frame(height: 52)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                        selectedDate = date
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}
