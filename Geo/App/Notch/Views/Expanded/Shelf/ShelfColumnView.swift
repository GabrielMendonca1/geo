import SwiftUI
import AppKit

struct NotchCard: View {
    let entry: NotchHistoryEntry

    private let cardWidth: CGFloat = 162
    private let cardHeight: CGFloat = 130

    var body: some View {
        ZStack(alignment: .bottom) {
            background
            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )
            footer
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .overlay(alignment: .topLeading) { typeBadge }
    }

    @ViewBuilder
    private var background: some View {
        if let image = entry.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.white.opacity(0.06)
                VStack(spacing: 8) {
                    Image(systemName: entry.glyph)
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(entry.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.glyph)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(0.2)))
            Text(entry.relativeTime)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 4)
            if let size = entry.sizeText {
                Text(size)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity)
    }

    private var typeBadge: some View {
        Image(systemName: entry.glyph)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.black.opacity(0.35))
            )
            .padding(8)
    }
}
