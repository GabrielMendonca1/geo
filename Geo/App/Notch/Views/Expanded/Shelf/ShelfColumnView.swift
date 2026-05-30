import SwiftUI

struct NotchCard: View {
    let block: BlockEntity
    let tag: Tag?

    private let cardWidth: CGFloat = 168
    private let cardHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tag {
                HStack(spacing: 5) {
                    Circle()
                        .fill(tag.color.swiftUIColor)
                        .frame(width: 6, height: 6)
                    Text(tag.name)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Text(block.displayTitle.isEmpty ? "Untitled" : block.displayTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            let preview = block.markdown.notchBlockPreview
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(4)
            }

            Spacer(minLength: 0)

            Text(relativeTime)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(11)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: block.lastEdited, relativeTo: Date())
    }
}
