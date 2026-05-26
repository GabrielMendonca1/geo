import SwiftUI

struct CalendarEventPill: View {
    let event: CalendarEvent
    let position: EventPillPosition
    let scale: CGFloat

    private var cornerRadius: CGFloat { 5 * scale }
    private var fontSize: CGFloat { 8 * scale }
    private var height: CGFloat { 14 * scale }
    private var horizontalPadding: CGFloat { 6 * scale }
    private var borderWidth: CGFloat { 1 * scale }

    var body: some View {
        HStack(spacing: 3 * scale) {
            if let iconName {
                Image(systemName: iconName)
                    .font(.system(size: fontSize - 0.5, weight: .medium))
                    .foregroundStyle(textColor)
                    .fixedSize()
            }
            Text(displayTitle)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(event.color.opacity(0.18))
        .overlay(
            pillShape
                .stroke(event.color.opacity(0.35), lineWidth: borderWidth)
        )
        .clipShape(pillShape)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var iconName: String? {
        switch event.type {
        case .block: return "doc.text"
        case .task: return "clock"
        case .holiday: return nil
        }
    }

    private var displayTitle: String {
        event.title
    }

    private var textColor: Color {
        colorScheme == .dark ? event.color.lighter(by: 0.2) : event.color.darker(by: 0.3)
    }

    private var pillShape: some Shape {
        UnevenRoundedRectangle(
            topLeadingRadius: leadingRadius,
            bottomLeadingRadius: leadingRadius,
            bottomTrailingRadius: trailingRadius,
            topTrailingRadius: trailingRadius
        )
    }

    private var leadingRadius: CGFloat {
        switch position {
        case .start, .single:
            return cornerRadius
        case .middle, .end:
            return 0
        }
    }

    private var trailingRadius: CGFloat {
        switch position {
        case .end, .single:
            return cornerRadius
        case .start, .middle:
            return 0
        }
    }
}
