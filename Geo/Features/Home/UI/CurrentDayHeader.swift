import SwiftUI

struct CurrentDayHeader: View {
    var body: some View {
        VStack(spacing: 24) {
            Text(Date().formatted(date: .complete, time: .omitted))
                .font(.system(size: 16, weight: .medium, design: .default))
                .foregroundStyle(Palette.foreground.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct YearNavigationHeader: View {
    @Binding var selectedYear: Int
    let selectedDayId: String?

    private static var dayIdFormatter: DateFormatter { DateFormatters.dayId }

    private static let dateTextFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f
    }()

    private var displayDate: Date {
        if let dayId = selectedDayId,
           let date = Self.dayIdFormatter.date(from: dayId) {
            return date
        }
        return Date()
    }

    private var dateText: String {
        Self.dateTextFormatter.string(from: displayDate)
    }

    var body: some View {
        Text(dateText)
            .font(.system(size: 12, weight: .medium, design: .default))
            .foregroundStyle(Palette.foreground.opacity(0.6))
            .tracking(0.5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}
