import SwiftUI
import AppKit
import Combine

struct NodesPane: View {
    @EnvironmentObject private var blocksViewModel: BlocksViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.tabRouter) private var tabRouter
    @ObservedObject private var graphStore = GraphStore.shared
    @State private var pendingFocus: FocusRequest?
    @AppStorage("nodesPane.splitFraction") private var splitFraction: Double = 0.5
    @AppStorage("nodesPane.leftHidden") private var leftHidden: Bool = false
    @State private var liveFraction: Double? = nil

    private let handleWidth: CGFloat = 12
    private let minPaneWidth: CGFloat = 240

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let minFrac = min(0.5, Double(minPaneWidth / max(total, 1)))
            let maxFrac = 1.0 - minFrac
            let raw = liveFraction ?? splitFraction
            let effective = min(max(raw, minFrac), maxFrac)
            let leftWidth = max(0, total * CGFloat(effective) - handleWidth / 2)
            let rightWidth = max(0, total - leftWidth - handleWidth)

            HStack(spacing: 0) {
                BlocksPane(externalFocus: pendingFocus)
                    .frame(width: leftWidth)
                    .clipped()

                ResizeDividerHandle(
                    width: handleWidth,
                    isActiveCheck: { [tabRouter] in tabRouter.selectedTab == .nodes },
                    onDragChanged: { deltaPx in
                        let denom = Double(max(total, 1))
                        let next = splitFraction + Double(deltaPx) / denom
                        liveFraction = min(max(next, minFrac), maxFrac)
                    },
                    onDragEnded: {
                        if let f = liveFraction { splitFraction = f }
                        liveFraction = nil
                    }
                )

                GraphView(
                    graph: graphStore.graph,
                    seedPositions: graphStore.cachedPositions,
                    wasSettled: graphStore.simulationSettled,
                    externalChangeSignal: graphStore.externalChangeSignal,
                    onLayoutChange: { positions, settled in
                        graphStore.updateLayoutCache(positions: positions, settled: settled)
                    }
                ) { id in
                    if let blockId = graphStore.idLookup[id] {
                        pendingFocus = FocusRequest(blockId: blockId, token: UUID())
                        openWindow(value: blockId)
                    }
                }
                .frame(width: rightWidth)
                .clipped()
            }
        }
        .task {
            graphStore.startObserving(blocksViewModel)
        }
    }
}

private struct ResizeDividerHandle: NSViewRepresentable {
    let width: CGFloat
    let isActiveCheck: () -> Bool
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> DividerNSView {
        let view = DividerNSView()
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.isActiveCheck = isActiveCheck
        return view
    }

    func updateNSView(_ nsView: DividerNSView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.isActiveCheck = isActiveCheck
    }

    @MainActor
    final class DividerNSView: NSView {
        var onDragChanged: ((CGFloat) -> Void)?
        var onDragEnded: (() -> Void)?
        var isActiveCheck: (() -> Bool)?

        private var trackingArea: NSTrackingArea?
        private var dragStartX: CGFloat?
        private var lastDeltaReported: CGFloat = 0
        private var isHovered: Bool = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
        private var isDragging: Bool = false { didSet { if oldValue != isDragging { needsDisplay = true } } }

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard isActiveCheck?() ?? true else { return nil }
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
                trackingArea = nil
            }
            let options: NSTrackingArea.Options = [
                .cursorUpdate,
                .mouseEnteredAndExited,
                .activeInActiveApp,
                .inVisibleRect
            ]
            let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseEntered(with event: NSEvent) {
            isHovered = true
        }

        override func mouseExited(with event: NSEvent) {
            if !isDragging { isHovered = false }
        }

        override func mouseDown(with event: NSEvent) {
            dragStartX = event.locationInWindow.x
            lastDeltaReported = 0
            isDragging = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStartX else { return }
            let dx = event.locationInWindow.x - start
            if dx != lastDeltaReported {
                lastDeltaReported = dx
                onDragChanged?(dx)
            }
        }

        override func mouseUp(with event: NSEvent) {
            dragStartX = nil
            lastDeltaReported = 0
            isDragging = false
            let localInView = convert(event.locationInWindow, from: nil)
            isHovered = bounds.contains(localInView)
            onDragEnded?()
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let centerX = bounds.midX
            let centerY = bounds.midY

            if isDragging {
                let w: CGFloat = 3
                let h: CGFloat = 48
                let rect = NSRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: w / 2, yRadius: w / 2).fill()
            } else if isHovered {
                let w: CGFloat = 2
                let h: CGFloat = 36
                let rect = NSRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h)
                NSColor.separatorColor.withAlphaComponent(0.45).setFill()
                NSBezierPath(roundedRect: rect, xRadius: w / 2, yRadius: w / 2).fill()
            } else {
                let w: CGFloat = 0.5
                let rect = NSRect(x: centerX - w / 2, y: 0, width: w, height: bounds.height)
                NSColor.separatorColor.withAlphaComponent(0.2).setFill()
                rect.fill()
            }
        }
    }
}
