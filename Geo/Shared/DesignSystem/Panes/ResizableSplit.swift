import SwiftUI
import AppKit

// MARK: - ThreeColumnSplit — sidebar | center | right with draggable dividers

struct ThreeColumnSplit<Left: View, Center: View, Right: View>: View {
    @Binding var leftWidth: CGFloat
    @Binding var rightWidth: CGFloat
    var leftRange: ClosedRange<CGFloat> = 200...460
    var rightRange: ClosedRange<CGFloat> = 220...560
    var showCenter: Bool = true
    let left: Left
    let center: Center
    let right: Right

    // Transient widths while dragging — the @AppStorage-backed bindings are written ONCE on
    // drag end (g-triad #7), not on every onLive tick (which would hammer UserDefaults).
    @State private var liveLeft: CGFloat?
    @State private var liveRight: CGFloat?

    init(
        leftWidth: Binding<CGFloat>,
        rightWidth: Binding<CGFloat>,
        leftRange: ClosedRange<CGFloat> = 200...460,
        rightRange: ClosedRange<CGFloat> = 220...560,
        showCenter: Bool = true,
        @ViewBuilder left: () -> Left,
        @ViewBuilder center: () -> Center,
        @ViewBuilder right: () -> Right
    ) {
        _leftWidth = leftWidth
        _rightWidth = rightWidth
        self.leftRange = leftRange
        self.rightRange = rightRange
        self.showCenter = showCenter
        self.left = left()
        self.center = center()
        self.right = right()
    }

    var body: some View {
        GeometryReader { geo in
            let lw = (liveLeft ?? leftWidth).clamped(to: leftRange)
            let rw = (liveRight ?? rightWidth).clamped(to: rightRange)
            // Columns flush; the draggable handles are an OVERLAY on top (highest z-order) so they win
            // the mouse over the NSView-backed columns (text editor / graph / sidebar list), which a
            // thin divider sandwiched between them as an HStack sibling never could.
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    left.frame(width: lw)
                    if showCenter {
                        center.frame(maxWidth: .infinity, maxHeight: .infinity)
                        right.frame(width: rw)
                    } else {
                        right.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                DividerHandle(
                    base: { lw },
                    range: leftRange,
                    inverted: false,
                    onLive: { liveLeft = $0 },
                    onCommit: { if let v = liveLeft { leftWidth = v.clamped(to: leftRange) }; liveLeft = nil }
                )
                .frame(height: geo.size.height)
                .position(x: lw, y: geo.size.height / 2)

                if showCenter {
                    DividerHandle(
                        base: { rw },
                        range: rightRange,
                        inverted: true,
                        onLive: { liveRight = $0 },
                        onCommit: { if let v = liveRight { rightWidth = v.clamped(to: rightRange) }; liveRight = nil }
                    )
                    .frame(height: geo.size.height)
                    .position(x: geo.size.width - rw, y: geo.size.height / 2)
                }
            }
        }
    }
}

// MARK: - TwoColumnSplit — flexible left | fixed-width right with a draggable divider

// Used when the sidebar is hidden (editor | graph). Same overlay+DividerHandle mechanism as
// ThreeColumnSplit's right divider — the previous static 1pt line here was not draggable.
struct TwoColumnSplit<Left: View, Right: View>: View {
    @Binding var rightWidth: CGFloat
    var rightRange: ClosedRange<CGFloat> = 220...560
    let left: Left
    let right: Right

    @State private var liveRight: CGFloat?

    init(
        rightWidth: Binding<CGFloat>,
        rightRange: ClosedRange<CGFloat> = 220...560,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) {
        _rightWidth = rightWidth
        self.rightRange = rightRange
        self.left = left()
        self.right = right()
    }

    var body: some View {
        GeometryReader { geo in
            let rw = (liveRight ?? rightWidth).clamped(to: rightRange)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    left.frame(maxWidth: .infinity, maxHeight: .infinity)
                    right.frame(width: rw)
                }
                DividerHandle(
                    base: { rw },
                    range: rightRange,
                    inverted: true,
                    onLive: { liveRight = $0 },
                    onCommit: { if let v = liveRight { rightWidth = v.clamped(to: rightRange) }; liveRight = nil }
                )
                .frame(height: geo.size.height)
                .position(x: geo.size.width - rw, y: geo.size.height / 2)
            }
        }
    }
}

// MARK: - DividerHandle — 12pt AppKit handle (resize, never window-drag, ↔ cursor, no flicker)

private struct DividerHandle: View {
    let base: () -> CGFloat
    let range: ClosedRange<CGFloat>
    let inverted: Bool          // right divider: dragging left widens the right column
    let onLive: (CGFloat) -> Void
    let onCommit: () -> Void

    var body: some View {
        DividerRepresentable(base: base, range: range, inverted: inverted, onLive: onLive, onCommit: onCommit)
            .frame(width: 12)
    }
}

private struct DividerRepresentable: NSViewRepresentable {
    let base: () -> CGFloat
    let range: ClosedRange<CGFloat>
    let inverted: Bool
    let onLive: (CGFloat) -> Void
    let onCommit: () -> Void

    func makeNSView(context: Context) -> DividerNSView { DividerNSView() }

    func updateNSView(_ view: DividerNSView, context: Context) {
        view.base = base
        view.range = range
        view.inverted = inverted
        view.onLive = onLive
        view.onCommit = onCommit
    }
}

private final class DividerNSView: NSView {
    var base: () -> CGFloat = { 0 }
    var range: ClosedRange<CGFloat> = 0...0
    var inverted = false
    var onLive: (CGFloat) -> Void = { _ in }
    var onCommit: () -> Void = {}

    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0
    private var dragging = false
    private var hovering = false
    private var cursorPushed = false

    // Kills the AppKit window-drag: the window is isMovableByWindowBackground, so any non-opaque
    // region whose view reports mouseDownCanMoveWindow == true MOVES THE WINDOW on mouse-down.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Claim the point so this handle beats the column NSViews (text editor / list) underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    // ↔ cursor via push/pop on enter/exit. NO .cursorUpdate — that plus a layout-changing hover
    // flag was the old flicker loop; here the line width is constant, so nothing feeds back.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; pushCursor(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) {
        hovering = false; needsDisplay = true
        if !dragging { popCursor() }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        startX = event.locationInWindow.x      // window space → stable while the handle repositions
        startWidth = base()
        pushCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let dx = event.locationInWindow.x - startX
        let delta = inverted ? -dx : dx
        onLive((startWidth + delta).clamped(to: range))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onCommit()
        hovering = bounds.contains(convert(event.locationInWindow, from: nil))
        if !hovering { popCursor() }
        needsDisplay = true
    }

    private func pushCursor() {
        guard !cursorPushed else { return }
        NSCursor.resizeLeftRight.push()
        cursorPushed = true
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { popCursor() }
    }

    deinit { if cursorPushed { NSCursor.pop() } }

    private static let lineColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1)
            : NSColor(white: 0.88, alpha: 1)
    }

    // Hover changes COLOR only — never the line width or the view frame — so no layout/tracking loop.
    override func draw(_ dirtyRect: NSRect) {
        (hovering ? NSColor.controlAccentColor : Self.lineColor).setFill()
        let x = (bounds.width - 1) / 2
        NSBezierPath(rect: NSRect(x: x, y: 0, width: 1, height: bounds.height)).fill()
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(range.lowerBound, self), range.upperBound)
    }
}
