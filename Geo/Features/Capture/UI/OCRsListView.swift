import SwiftUI
import AppKit

struct OCRsListView: View {
    @ObservedObject var viewModel: CaptureViewModel

    var body: some View {
        if viewModel.filteredCaptures.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 24))
                    .foregroundColor(Palette.tertiaryForeground.opacity(0.3))
                Text("No captures yet")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.tertiaryForeground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.filteredCaptures) { capture in
                        OCRCaptureRow(capture: capture, onDelete: {
                            Task { await viewModel.deleteCapture(id: capture.id) }
                        })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }
}

struct OCRCaptureRow: View {
    let capture: CaptureItem
    var onDelete: () -> Void

    private static let fmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let img = capture.previewImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 42)
                        .clipped()
                        .cornerRadius(4)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Palette.tertiaryForeground.opacity(0.1))
                        .frame(width: 56, height: 42)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 14))
                                .foregroundColor(Palette.tertiaryForeground)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let text = capture.extractedText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                    } else {
                        Text(capture.fileName)
                            .font(.system(size: 11))
                            .foregroundColor(Palette.tertiaryForeground)
                            .lineLimit(1)
                    }
                    Text(Self.fmt.localizedString(for: capture.timestamp, relativeTo: Date()))
                        .font(.system(size: 9))
                        .foregroundColor(Palette.tertiaryForeground)
                }

                Spacer()
            }

            HStack(spacing: 6) {
                Button { copyImage() } label: {
                    Label("Image", systemImage: "photo.on.rectangle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let text = capture.extractedText, !text.isEmpty {
                    Button { copyText(text) } label: {
                        Label("Text", systemImage: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(Palette.agentCard))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(Palette.agentBorder), lineWidth: 0.5)
        )
    }

    private func copyImage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = capture.fullImageData(), let img = NSImage(data: data) {
            pb.writeObjects([img])
            if let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        } else if let img = capture.previewImage, let tiff = img.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    private func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
