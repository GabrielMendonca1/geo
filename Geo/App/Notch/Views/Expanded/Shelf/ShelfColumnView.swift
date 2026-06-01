import SwiftUI
import AppKit

struct NotchCard: View {
    let item: NotchFeedItem
    let tag: Tag?

    private let cardWidth: CGFloat = 168
    private let cardHeight: CGFloat = 132

    @State private var thumbnail: NSImage?
    @State private var sizeText: String?

    var body: some View {
        Group {
            switch item {
            case .capture(let capture): imageCard(capture)
            case .block(let block): blockCard(block)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { open() }
        .pointingHandCursor()
        .task(id: captureKey) {
            guard case .capture(let capture) = item else { return }
            let loaded = await NotchThumbnailCache.shared.load(capture)
            thumbnail = loaded.image
            sizeText = loaded.size
        }
    }

    private var captureKey: String? {
        if case .capture(let capture) = item { return capture.id.uuidString }
        return nil
    }

    private func open() {
        switch item {
        case .capture(let capture): openCapture(capture)
        case .block(let block):
            NotificationCenter.default.post(
                name: .openBlockEditor,
                object: nil,
                userInfo: ["blockId": block.id]
            )
        }
    }

    private func openCapture(_ capture: CaptureItem) {
        if let url = capture.sourceURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let data = capture.fullImageData() else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("geo-\(capture.id.uuidString).png")
        try? data.write(to: tmp)
        NSWorkspace.shared.open(tmp)
    }

    @ViewBuilder
    private func imageCard(_ capture: CaptureItem) -> some View {
        ZStack(alignment: .bottom) {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.06)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.white.opacity(0.2)))
                Text(relativeTime(capture.timestamp))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 4)
                if let size = captureSize(capture) {
                    Text(size).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .overlay(alignment: .topLeading) { badge("photo") }
    }

    @ViewBuilder
    private func blockCard(_ block: BlockEntity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tag {
                HStack(spacing: 5) {
                    Circle().fill(tag.color.swiftUIColor).frame(width: 6, height: 6)
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
            Text(relativeTime(block.lastEdited))
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.06))
    }

    private func badge(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.black.opacity(0.35))
            )
            .padding(8)
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func captureSize(_ capture: CaptureItem) -> String? {
        let bytes: Int?
        if let n = capture.imageData?.count, n > 0 {
            bytes = n
        } else if let url = capture.sourceURL,
                  let n = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            bytes = n
        } else {
            bytes = capture.previewData?.count
        }
        guard let count = bytes, count > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
