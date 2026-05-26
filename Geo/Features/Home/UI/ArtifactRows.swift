import SwiftUI

struct BlockArtifactRow: View {
    let block: BlockEntity
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Button {
            openWindow(id: "editor", value: block.id)
        } label: {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(Palette.foreground)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(block.displayTitle)
                        .font(.subheadline)
                        .lineLimit(1)

                    Text(block.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Palette.tertiaryForeground)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Palette.tertiaryForeground.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.background)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Palette.border.opacity(0.15), lineWidth: GeoStyle.Border.width)
            )
        }
        .plainNoFocusButton()
    }

}

struct CaptureArtifactRow: View {
    let capture: CaptureItem

    var body: some View {
        HStack {
            if let preview = capture.previewImage {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 24)
                    .cornerRadius(4)
            } else {
                Image(systemName: "photo")
                    .frame(width: 32, height: 24)
                    .foregroundStyle(Palette.tertiaryForeground)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(capture.fileName)
                    .font(.subheadline)
                    .lineLimit(1)

                if let text = capture.extractedText, !text.isEmpty {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(Palette.tertiaryForeground)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Palette.tertiaryForeground.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.background)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Palette.border.opacity(0.15), lineWidth: GeoStyle.Border.width)
        )
    }
}

struct ArtifactBadge: View {
    let icon: String
    let count: Int
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11 * scale))
            Text("\(count)")
                .font(.system(size: 12 * scale, weight: .medium))
        }
        .foregroundStyle(Palette.tertiaryForeground)
    }
}

struct ArtifactSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(Palette.tertiaryForeground)
            .padding(.horizontal, 16)

            VStack(spacing: 6) {
                content()
            }
            .padding(.horizontal, 16)
        }
    }
}
