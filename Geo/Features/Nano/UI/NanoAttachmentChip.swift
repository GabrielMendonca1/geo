import SwiftUI

struct NanoAttachmentChip: View {
    let attachment: NanoAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.fileName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if case .image = attachment.kind {
                    Text("Image")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                } else if case .file(let url) = attachment.kind {
                    Text(url.pathExtension.uppercased())
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder private var thumbnail: some View {
        switch attachment.kind {
        case .image(let image, _):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .file:
            Image(systemName: attachment.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.0, green: 0.33, blue: 1.0))
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}
