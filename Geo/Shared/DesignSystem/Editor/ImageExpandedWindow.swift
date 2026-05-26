import SwiftUI
import AppKit

enum ImageExpandedWindow {
    private static var activePanel: NSPanel?

    static func show(image: NSImage, onDismiss: @escaping () -> Void) {
        guard activePanel == nil else { return }
        guard let screen = NSScreen.main else { return }

        let screenRect = screen.visibleFrame
        let panelRect = NSRect(
            x: screenRect.midX - screenRect.width * 0.4,
            y: screenRect.midY - screenRect.height * 0.4,
            width: screenRect.width * 0.8,
            height: screenRect.height * 0.8
        )

        let panel = NSPanel(
            contentRect: panelRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(Palette.background).withAlphaComponent(0.96)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        let contentView = ImageExpandedContentView(image: image) {
            panel.close()
        }
        panel.contentView = NSHostingView(rootView: contentView)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        activePanel = panel

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            activePanel = nil
            onDismiss()
        }
    }
}

private struct ImageExpandedContentView: View {
    let image: NSImage
    let onClose: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(Palette.background).opacity(0.01)
                    .onTapGesture(count: 2) { resetTransform() }
                    .onTapGesture(count: 1) { onClose() }

                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(0.5, min(lastScale * value, 10.0))
                            }
                            .onEnded { value in
                                lastScale = scale
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 12) {
                            Button { zoomOut() } label: {
                                Image(systemName: "minus.magnifyingglass")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .buttonStyle(.plain)

                            Text("\(Int(scale * 100))%")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .frame(width: 44)

                            Button { zoomIn() } label: {
                                Image(systemName: "plus.magnifyingglass")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .buttonStyle(.plain)

                            Divider().frame(height: 16)

                            Button { resetTransform() } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .buttonStyle(.plain)

                            Button { onClose() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundColor(Palette.foreground)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(16)
                    }
                    Spacer()
                }
            }
        }
        .onExitCommand { onClose() }
    }

    private func zoomIn() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = min(scale * 1.5, 10.0)
            lastScale = scale
        }
    }

    private func zoomOut() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = max(scale / 1.5, 0.5)
            lastScale = scale
        }
    }

    private func resetTransform() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            scale = 1.0
            lastScale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }
}
