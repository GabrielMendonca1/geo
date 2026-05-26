import SwiftUI

struct CalendarHeader: View {
    @Binding var currentMonth: Date
    @Binding var isSidebarOpen: Bool
    let scale: CGFloat
    let onTodayTap: () -> Void

    private static var monthYearFormatter: DateFormatter { DateFormatters.monthYear }

    private var monthYearText: String {
        Self.monthYearFormatter.string(from: currentMonth)
    }

    private var todayButtonText: String {
        NSLocalizedString("Today", comment: "Today button")
    }

    private var titleFontSize: CGFloat { 24 * scale }
    private var buttonFontSize: CGFloat { 11 * scale }
    private var buttonPadding: CGFloat { 6 * scale }

    var body: some View {
        HStack(alignment: .center, spacing: 12 * scale) {
            Text(monthYearText)
                .font(GeoStyle.Typography.titleFont(size: titleFontSize))
                .foregroundStyle(Palette.foreground)

            Spacer()

            Button(action: onTodayTap) {
                Text(todayButtonText)
                    .font(.system(size: buttonFontSize, weight: .medium))
                    .foregroundStyle(Palette.background)
                    .padding(.horizontal, buttonPadding * 1.5)
                    .padding(.vertical, buttonPadding)
                    .contentShape(Rectangle())
                    .background(Palette.foreground)
                    .clipShape(RoundedRectangle(cornerRadius: 6 * scale))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to today")
            .pointingHandCursor()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSidebarOpen.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13 * scale, weight: .medium))
                    .foregroundStyle(Palette.foreground.opacity(isSidebarOpen ? 1.0 : 0.4))
                    .padding(buttonPadding)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSidebarOpen ? "Hide sidebar" : "Show sidebar")
            .pointingHandCursor()
        }
        .padding(.horizontal, 24 * scale)
        .padding(.vertical, 6 * scale)
    }
}
