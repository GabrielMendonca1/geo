import SwiftUI

struct CalendarWeekdayHeader: View {
    let scale: CGFloat

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        return f
    }()

    private var weekdays: [String] {
        var symbols = Self.weekdayFormatter.shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let firstWeekday = Calendar.current.firstWeekday
        if firstWeekday == 2 {
            let sunday = symbols.removeFirst()
            symbols.append(sunday)
        }
        return symbols.map { $0.lowercased() }
    }

    private var fontSize: CGFloat { 12 * scale }
    private var height: CGFloat { 32 * scale }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { _, weekday in
                Text(weekday)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(Palette.tertiaryForeground)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
    }
}
