import SwiftUI

struct CalendarDayCell: View, Equatable {
    static func == (lhs: CalendarDayCell, rhs: CalendarDayCell) -> Bool {
        guard lhs.date == rhs.date else { return false }
        guard lhs.isCurrentMonth == rhs.isCurrentMonth else { return false }
        guard lhs.isToday == rhs.isToday else { return false }
        guard lhs.scale == rhs.scale else { return false }
        guard lhs.spanningEventRows == rhs.spanningEventRows else { return false }
        guard lhs.rowHeight == rhs.rowHeight else { return false }
        guard lhs.events.count == rhs.events.count else { return false }
        let lhsIds: [String] = lhs.events.map { $0.id }
        let rhsIds: [String] = rhs.events.map { $0.id }
        return lhsIds == rhsIds
    }

    let date: Date
    let events: [PositionedEvent]
    let isCurrentMonth: Bool
    let isToday: Bool
    let scale: CGFloat
    let spanningEventRows: Int
    let rowHeight: CGFloat
    let dayHeaderHeight: CGFloat
    let eventRowHeight: CGFloat
    let eventSpacing: CGFloat
    let onEventTap: (CalendarEvent) -> Void

    @State private var isShowingOverflowPopover = false

    private let calendar = Calendar.current

    private var dayNumber: Int {
        calendar.component(.day, from: date)
    }

    private var fontSize: CGFloat { 12 * scale }
    private var padding: CGFloat { 4 * scale }
    private var todayCircleSize: CGFloat { 24 * scale }

    private var spanningAreaHeight: CGFloat {
        guard spanningEventRows > 0 else { return 0 }
        return CGFloat(spanningEventRows) * (eventRowHeight + eventSpacing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dayNumberView
                .frame(maxWidth: .infinity, minHeight: dayHeaderHeight, alignment: .topTrailing)

            if spanningEventRows > 0 {
                Color.clear
                    .frame(height: spanningAreaHeight)
            }

            VStack(alignment: .leading, spacing: eventSpacing) {
                if !habitEvents.isEmpty {
                    habitDotRow
                }

                ForEach(visibleEvents) { positioned in
                    CalendarEventPill(event: positioned.event, position: positioned.position, scale: scale)
                        .frame(height: eventRowHeight)
                        .onTapGesture { onEventTap(positioned.event) }
                }

                if overflowCount > 0 {
                    Button {
                        isShowingOverflowPopover = true
                    } label: {
                        Text("+\(overflowCount) more")
                            .font(.system(size: 10 * scale))
                            .foregroundStyle(Palette.tertiaryForeground)
                            .padding(.leading, padding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .popover(isPresented: $isShowingOverflowPopover, arrowEdge: .bottom) {
                        overflowPopover
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, padding)

            Spacer(minLength: 0)
        }
        .padding(.top, padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityDateFormatter.string(from: date))
        .accessibilityValue(events.isEmpty ? "No events" : "\(events.count) event\(events.count == 1 ? "" : "s")")
    }

    private var dayNumberView: some View {
        Group {
            if isToday {
                Text("\(dayNumber)")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(Palette.background)
                    .frame(width: todayCircleSize, height: todayCircleSize)
                    .background(Palette.foreground)
                    .clipShape(Circle())
                    .padding(.trailing, 4 * scale)
                    .padding(.top, 4 * scale)
            } else {
                Text("\(dayNumber)")
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(dayNumberColor)
                    .padding(.trailing, 5 * scale)
                    .padding(.top, 4 * scale)
            }
        }
    }

    private var dayNumberColor: Color {
        if !isCurrentMonth {
            return Palette.tertiaryForeground.opacity(0.3)
        }
        return Palette.foreground
    }

    private var habitEvents: [PositionedEvent] {
        events.filter { $0.event.isRecurringHabit }
    }

    private var pillEvents: [PositionedEvent] {
        events.filter { !$0.event.isRecurringHabit }
    }

    private var habitDotRowHeight: CGFloat { 8 * scale }

    private var habitDotRow: some View {
        HStack(spacing: 3 * scale) {
            ForEach(habitEvents.prefix(6)) { positioned in
                CalendarEventPill(event: positioned.event, position: positioned.position, scale: scale)
                    .onTapGesture { onEventTap(positioned.event) }
            }
            if habitEvents.count > 6 {
                Text("+\(habitEvents.count - 6)")
                    .font(.system(size: 8 * scale))
                    .foregroundStyle(Palette.tertiaryForeground)
            }
        }
        .frame(height: habitDotRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var availableContentHeight: CGFloat {
        let usedByHeader = dayHeaderHeight
        let usedBySpanning = spanningAreaHeight
        let usedByPadding = padding
        let usedByHabits = habitEvents.isEmpty ? 0 : habitDotRowHeight + eventSpacing
        return max(0, rowHeight - usedByHeader - usedBySpanning - usedByPadding - usedByHabits)
    }

    private var maxFittingEvents: Int {
        let overflowRowHeight = 14 * scale
        let singlePillTotal = eventRowHeight + eventSpacing
        guard singlePillTotal > 0 else { return 0 }
        var count = 0
        var used: CGFloat = 0
        while used + singlePillTotal <= availableContentHeight {
            count += 1
            used += singlePillTotal
        }
        if count < pillEvents.count {
            while count > 0 && used + overflowRowHeight > availableContentHeight {
                count -= 1
                used -= singlePillTotal
            }
        }
        return max(0, count)
    }

    private var visibleEvents: [PositionedEvent] {
        return Array(pillEvents.prefix(maxFittingEvents))
    }

    private var overflowEvents: [PositionedEvent] {
        return Array(pillEvents.dropFirst(maxFittingEvents))
    }

    private var overflowCount: Int {
        return overflowEvents.count
    }

    private var overflowPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.foreground)

            Divider()

            if overflowEvents.isEmpty {
                Text("No hidden events")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiaryForeground)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(overflowEvents) { positioned in
                            Button {
                                isShowingOverflowPopover = false
                                onEventTap(positioned.event)
                            } label: {
                                overflowEventRow(positioned.event)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func overflowEventRow(_ event: CalendarEvent) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(event.color)
                .frame(width: 8, height: 8)

            Text(event.title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.foreground)
                .lineLimit(1)

            Spacer()

            Text(eventTimeText(event))
                .font(.system(size: 10))
                .foregroundStyle(Palette.tertiaryForeground)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private static let accessibilityDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()

    private static var timeFormatter: DateFormatter { DateFormatters.shortTime }

    private func eventTimeText(_ event: CalendarEvent) -> String {
        if case .holiday = event.type {
            return "All day"
        }

        let startText = Self.timeFormatter.string(from: event.startDate)

        guard let endDate = event.endDate else { return startText }
        return "\(startText) - \(Self.timeFormatter.string(from: endDate))"
    }
}
