import SwiftUI

struct CalendarGrid: View, Equatable {
    @Binding var currentMonth: Date
    let events: [Date: [PositionedEvent]]
    let spanningEvents: [Date: [WeekSpanningEvent]]
    let scale: CGFloat
    let containerWidth: CGFloat
    let containerHeight: CGFloat
    let onEventTap: (CalendarEvent) -> Void

    private let calendar = Calendar.current
    private let weeksBack = 52
    private let weeksForward = 52
    private var totalWeeks: Int { weeksBack + weeksForward + 1 }

    private var rowHeight: CGFloat { containerHeight / 6 }
    private var cellWidth: CGFloat { containerWidth / 7 }
    private var eventRowHeight: CGFloat { 18 * scale }
    private var eventSpacing: CGFloat { 3 * scale }
    private var dayHeaderHeight: CGFloat { 30 * scale }

    static func == (lhs: CalendarGrid, rhs: CalendarGrid) -> Bool {
        lhs.currentMonth == rhs.currentMonth &&
        lhs.scale == rhs.scale &&
        lhs.containerWidth == rhs.containerWidth &&
        lhs.containerHeight == rhs.containerHeight &&
        lhs.events.count == rhs.events.count &&
        lhs.spanningEvents.count == rhs.spanningEvents.count
    }

    var body: some View {
        let _ = PerformanceTracker.shared.recordRender("CalendarGrid")
        CalendarGridScroller(
            currentMonth: $currentMonth,
            weeksBack: weeksBack,
            totalWeeks: totalWeeks,
            rowHeight: rowHeight,
            calendar: calendar
        ) { index in
            let weekStart = weekStartForIndex(index)
            weekRow(startingFrom: weekStart)
        }
    }

    private func weekStartForIndex(_ index: Int) -> Date {
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysToSubtract = (weekday - calendar.firstWeekday + 7) % 7
        let initialWeekStart = calendar.date(byAdding: .day, value: -daysToSubtract, to: calendar.startOfDay(for: today)) ?? today
        let offset = index - weeksBack
        return calendar.date(byAdding: .day, value: offset * 7, to: initialWeekStart) ?? initialWeekStart
    }

    private func weekRow(startingFrom weekStart: Date) -> some View {
        let week = (0..<7).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: dayOffset, to: weekStart)
        }
        let thursday = week[3]
        let weekSpanning = spanningEvents[calendar.startOfDay(for: weekStart)] ?? []

        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(week, id: \.self) { date in
                    let isCurrentMonth = calendar.isDate(date, equalTo: thursday, toGranularity: .month)
                    let isToday = calendar.isDateInToday(date)
                    let singleDayEvents = singleDayEventsForDate(date)

                    EquatableView(content: CalendarDayCell(
                        date: date,
                        events: singleDayEvents,
                        isCurrentMonth: isCurrentMonth,
                        isToday: isToday,
                        scale: scale,
                        spanningEventRows: weekSpanning.count,
                        rowHeight: rowHeight,
                        dayHeaderHeight: dayHeaderHeight,
                        eventRowHeight: eventRowHeight,
                        eventSpacing: eventSpacing,
                        onEventTap: onEventTap
                    ))
                    .frame(width: cellWidth)
                    .frame(height: rowHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Palette.border.opacity(0.15))
                            .frame(height: 1)
                    }
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Palette.border.opacity(0.20))
                            .frame(width: 1)
                    }
                }
            }

            ForEach(weekSpanning) { spanning in
                spanningEventView(spanning)
            }
        }
    }

    private func spanningEventView(_ spanning: WeekSpanningEvent) -> some View {
        let inset = 4 * scale
        let xOffset = CGFloat(spanning.startDayIndex) * cellWidth + inset
        let width = CGFloat(spanning.spanDays) * cellWidth - (inset * 2)
        let yOffset = dayHeaderHeight + CGFloat(spanning.row) * (eventRowHeight + eventSpacing)

        return CalendarEventPill(event: spanning.event, position: spanning.position, scale: scale)
            .frame(width: width, height: eventRowHeight)
            .offset(x: xOffset, y: yOffset)
            .pointingHandCursor()
            .onTapGesture { onEventTap(spanning.event) }
    }

    private func singleDayEventsForDate(_ date: Date) -> [PositionedEvent] {
        let startOfDay = calendar.startOfDay(for: date)
        return (events[startOfDay] ?? []).filter { $0.position == .single }
    }
}

private struct CalendarGridScroller<Content: View>: View {
    @Binding var currentMonth: Date
    let weeksBack: Int
    let totalWeeks: Int
    let rowHeight: CGFloat
    let calendar: Calendar
    @ViewBuilder let content: (Int) -> Content

    @State private var scrollPosition: Int?
    @State private var isUpdatingFromScroll = false
    @State private var hasPerformedInitialScroll = false
    @State private var initialWeekStart: Date = {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysToSubtract = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -daysToSubtract, to: calendar.startOfDay(for: today)) ?? today
    }()

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<totalWeeks, id: \.self) { index in
                        content(index)
                            .frame(height: rowHeight)
                            .drawingGroup()
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrollPosition)
            .onAppear {
                guard !hasPerformedInitialScroll else { return }
                hasPerformedInitialScroll = true
                isUpdatingFromScroll = true
                DispatchQueue.main.async {
                    scrollProxy.scrollTo(weeksBack, anchor: .top)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isUpdatingFromScroll = false
                    }
                }
            }
            .onChange(of: scrollPosition) { _, newPosition in
                guard !isUpdatingFromScroll, hasPerformedInitialScroll else { return }
                if let index = newPosition {
                    let weekStart = weekStartForIndex(index)
                    guard let thursday = calendar.date(byAdding: .day, value: 3, to: weekStart) else { return }
                    if !calendar.isDate(thursday, equalTo: currentMonth, toGranularity: .month) {
                        isUpdatingFromScroll = true
                        currentMonth = thursday
                        isUpdatingFromScroll = false
                    }
                }
            }
            .onChange(of: currentMonth) { _, newValue in
                guard !isUpdatingFromScroll else { return }
                if let targetIndex = indexForDate(newValue) {
                    isUpdatingFromScroll = true
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scrollProxy.scrollTo(targetIndex, anchor: .top)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        isUpdatingFromScroll = false
                    }
                }
            }
        }
    }

    private func weekStartForIndex(_ index: Int) -> Date {
        let offset = index - weeksBack
        return calendar.date(byAdding: .day, value: offset * 7, to: initialWeekStart) ?? initialWeekStart
    }

    private func indexForDate(_ date: Date) -> Int? {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let daysToSubtract = (weekday - calendar.firstWeekday + 7) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -daysToSubtract, to: dayStart) else { return nil }

        let daysDiff = calendar.dateComponents([.day], from: initialWeekStart, to: weekStart).day ?? 0
        let weekOffset = daysDiff >= 0 ? daysDiff / 7 : (daysDiff - 6) / 7
        let index = weeksBack + weekOffset
        guard index >= 0, index < totalWeeks else { return nil }
        return index
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components) ?? date
    }
}
