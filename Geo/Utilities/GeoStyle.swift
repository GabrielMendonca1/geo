import AppKit
import SwiftUI

enum GeoStyle {

    enum Typography {
        static let editorFontSize: CGFloat = 13
        static let editorLineHeight: CGFloat = 1.5
        static let editorLetterSpacing: CGFloat = 0.3
        static let titleFontSize: CGFloat = 24
        static let minScale: CGFloat = 0.85
        static let maxScale: CGFloat = 1.3

        static func titleFont(size: CGFloat) -> Font {
            FontManager.monaSansFont(size: size, weight: .semibold)
        }

        static func editorFont(size: CGFloat) -> Font {
            FontManager.geistMonoFont(size: size, weight: .regular)
        }
    }

    enum Spacing {
        static let editorPadding: CGFloat = 24
        static let editorPaddingHorizontal: CGFloat = 24
        static let editorPaddingVertical: CGFloat = 48
        static let editorVStackSpacing: CGFloat = 12

        static let listBaseIndent: CGFloat = 24
        static let listLevelIndent: CGFloat = 20
        static let bulletSize: CGFloat = 5
        static let bulletOffset: CGFloat = 9
        static let checkboxSize: CGFloat = 14
        static let checkboxOffset: CGFloat = 5
        static let blockquoteBarWidth: CGFloat = 2.5
        static let blockquoteBarOffset: CGFloat = 8
        static let blockquoteIndent: CGFloat = 20
    }


    enum Layout {
        static let baseEditorWindowSize = CGSize(width: 430, height: 600)
        static let tasksPaneScaleBoost: CGFloat = 1.15
        static let windowCornerRadius: CGFloat = 10
    }

    enum Colors {
        static let aestheticDarkBg = Color(red: 0.07, green: 0.07, blue: 0.08)
        static let aestheticLightText = Color(white: 0.85)
        static let aestheticCursor = Color(red: 0.2, green: 0.5, blue: 1.0)
        static let geoBlue = Color(red: 0.0, green: 0.33, blue: 1.0)
        static let geoBlueDark = Color(red: 0.1, green: 0.42, blue: 1.0)

        static var cursorColor: NSColor {
            NSColor.green
        }

        enum EventPill {
            static let task = Color(red: 0.35, green: 0.55, blue: 1.0)
            static let block = Color(red: 0.6, green: 0.55, blue: 0.85)
            static let holiday = Color(red: 0.4, green: 0.75, blue: 0.55)
            static let deadline = Color(red: 0.95, green: 0.5, blue: 0.45)
            static let meeting = Color(red: 0.95, green: 0.7, blue: 0.35)
            static let reminderDefault = Color(nsColor: .systemBlue)
            static let palette: [Color] = [
                Color(nsColor: .systemBlue),
                Color(nsColor: .systemTeal),
                Color(nsColor: .systemGreen),
                Color(nsColor: .systemOrange),
                Color(nsColor: .systemPink),
                Color(nsColor: .systemPurple)
            ]
        }
    }

    enum Cursor {
        static let blinkInterval: TimeInterval = 0.53
    }

    enum Border {
        static let width: CGFloat = 1
    }
}

enum EventPillPosition {
    case start
    case middle
    case end
    case single
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua:
                return NSColor(dark)
            default:
                return NSColor(light)
            }
        })
    }

    func lighter(by amount: CGFloat = 0.2) -> Color {
        adjustBrightness(by: amount)
    }

    func darker(by amount: CGFloat = 0.2) -> Color {
        adjustBrightness(by: -amount)
    }

    private func adjustBrightness(by amount: CGFloat) -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        NSColor(self).usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let newBrightness = max(0, min(1, brightness + amount))
        let newSaturation = amount > 0 ? max(0, saturation - amount * 0.3) : min(1, saturation - amount * 0.2)

        return Color(hue: hue, saturation: newSaturation, brightness: newBrightness, opacity: alpha)
    }
}

struct PlainNoFocusButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointingHandCursor()
    }
}

private struct TooltipBubbleView: View {
    let content: TooltipContent

    var body: some View {
        HStack(spacing: 6) {
            Text(content.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            if let shortcut = content.shortcut, !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.85))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.16))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: 0.1))
        )
        .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
        .fixedSize()
    }
}

private struct TooltipContent: Equatable {
    let title: String
    let shortcut: String?
}

@MainActor
private final class TooltipPanelController {
    static let shared = TooltipPanelController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<TooltipBubbleView>?
    private var hideWorkItem: DispatchWorkItem?
    private var observersInstalled = false

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private init() {}

    func show(content: TooltipContent, anchorRectInScreen: CGRect?) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if panel == nil || hostingView == nil {
            let hostingView = NSHostingView(rootView: TooltipBubbleView(content: content))
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = true
            panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.contentView = hostingView

            self.hostingView = hostingView
            self.panel = panel
            installObserversIfNeeded()
        }

        guard let panel, let hostingView else { return }
        hostingView.rootView = TooltipBubbleView(content: content)
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: max(40, fittingSize.width), height: max(20, fittingSize.height))
        panel.setContentSize(size)
        panel.setFrame(
            NSRect(
                origin: frameOrigin(for: size, anchorRectInScreen: anchorRectInScreen),
                size: size
            ),
            display: false
        )
        panel.orderFrontRegardless()
    }

    func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hideImmediately()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func hideImmediately() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    private func frameOrigin(for size: NSSize, anchorRectInScreen: CGRect?) -> NSPoint {
        if let anchorRectInScreen,
           let screen = screenForAnchorRect(anchorRectInScreen) {
            return anchoredFrameOrigin(for: size, anchorRectInScreen: anchorRectInScreen, screen: screen)
        }

        return cursorFrameOrigin(for: size)
    }

    private func cursorFrameOrigin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 10)

        if let screen = screenContainingPoint(mouse) {
            let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            origin.x = min(max(bounds.minX, origin.x), bounds.maxX - size.width)
            origin.y = min(max(bounds.minY, origin.y), bounds.maxY - size.height)
        }

        return origin
    }

    private func anchoredFrameOrigin(for size: NSSize, anchorRectInScreen: CGRect, screen: NSScreen) -> NSPoint {
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 8

        var origin = NSPoint(
            x: anchorRectInScreen.midX - (size.width / 2),
            y: anchorRectInScreen.maxY + gap
        )

        if origin.y + size.height > bounds.maxY {
            origin.y = anchorRectInScreen.minY - size.height - gap
        }

        origin.x = min(max(bounds.minX, origin.x), bounds.maxX - size.width)
        origin.y = min(max(bounds.minY, origin.y), bounds.maxY - size.height)

        return origin
    }

    private func screenContainingPoint(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
    }

    private func screenForAnchorRect(_ anchorRectInScreen: CGRect) -> NSScreen? {
        if let intersecting = NSScreen.screens.first(where: { $0.frame.intersects(anchorRectInScreen) }) {
            return intersecting
        }

        return screenContainingPoint(NSPoint(x: anchorRectInScreen.midX, y: anchorRectInScreen.midY))
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideImmediately()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideImmediately()
            }
        }
    }
}

private struct TooltipAnchorReader: NSViewRepresentable {
    @Binding var anchorRectInScreen: CGRect?

    final class Coordinator {
        var anchorRectInScreen: Binding<CGRect?>

        init(anchorRectInScreen: Binding<CGRect?>) {
            self.anchorRectInScreen = anchorRectInScreen
        }

        func updateAnchorRect(_ rect: CGRect?) {
            if anchorRectInScreen.wrappedValue != rect {
                anchorRectInScreen.wrappedValue = rect
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(anchorRectInScreen: $anchorRectInScreen)
    }

    func makeNSView(context: Context) -> TooltipAnchorNSView {
        let view = TooltipAnchorNSView()
        view.onFrameChange = context.coordinator.updateAnchorRect(_:)
        return view
    }

    func updateNSView(_ nsView: TooltipAnchorNSView, context: Context) {
        context.coordinator.anchorRectInScreen = $anchorRectInScreen
        nsView.onFrameChange = context.coordinator.updateAnchorRect(_:)
        nsView.reportFrame()
    }
}

private final class TooltipAnchorNSView: NSView {
    var onFrameChange: ((CGRect?) -> Void)?
    private var windowObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resetWindowObservers()
        reportFrame()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportFrame()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        reportFrame()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        clearWindowObservers()
    }

    func reportFrame() {
        guard let window else {
            onFrameChange?(nil)
            return
        }

        let rectInWindow = convert(bounds, to: nil)
        let rectInScreen = window.convertToScreen(rectInWindow)
        onFrameChange?(rectInScreen)
    }

    private func resetWindowObservers() {
        clearWindowObservers()

        guard let window else { return }
        let center = NotificationCenter.default

        windowObservers.append(
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                self?.reportFrame()
            }
        )

        windowObservers.append(
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.reportFrame()
            }
        )

        windowObservers.append(
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.reportFrame()
            }
        )
    }

    private func clearWindowObservers() {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll()
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let content: TooltipContent
    @State private var isHovering = false
    @State private var showWorkItem: DispatchWorkItem?
    @State private var anchorRectInScreen: CGRect?

    func body(content: Content) -> some View {
        content
            .background(TooltipAnchorReader(anchorRectInScreen: $anchorRectInScreen))
            .onHover { hovering in
                showWorkItem?.cancel()
                showWorkItem = nil
                isHovering = hovering

                if hovering {
                    let showDelay = TooltipPanelController.shared.isVisible ? 0.0 : 0.25
                    let workItem = DispatchWorkItem {
                        TooltipPanelController.shared.show(
                            content: self.content,
                            anchorRectInScreen: anchorRectInScreen
                        )
                    }
                    showWorkItem = workItem
                    if showDelay == 0 {
                        workItem.perform()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: workItem)
                    }
                } else {
                    TooltipPanelController.shared.scheduleHide(after: 0.1)
                }
            }
            .onChange(of: self.content) { _, newValue in
                guard isHovering else { return }
                TooltipPanelController.shared.show(content: newValue, anchorRectInScreen: anchorRectInScreen)
            }
            .onChange(of: anchorRectInScreen) { _, newValue in
                guard isHovering else { return }
                TooltipPanelController.shared.show(content: self.content, anchorRectInScreen: newValue)
            }
            .onDisappear {
                showWorkItem?.cancel()
                showWorkItem = nil
                isHovering = false
                TooltipPanelController.shared.hideImmediately()
            }
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != isHovering else { return }
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
                isHovering = hovering
            }
            .onDisappear {
                guard isHovering else { return }
                NSCursor.pop()
                isHovering = false
            }
    }
}

extension View {
    @ViewBuilder
    func glassEffectIfAvailable<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
        }
    }

    func plainNoFocusButton() -> some View {
        modifier(PlainNoFocusButton())
    }

    func hoverTooltip(_ text: String) -> some View {
        modifier(HoverTooltipModifier(content: TooltipContent(title: text, shortcut: nil)))
    }

    func hoverTooltip(title: String, shortcut: String? = nil) -> some View {
        modifier(HoverTooltipModifier(content: TooltipContent(title: title, shortcut: shortcut)))
    }

    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

extension Notification.Name {
    static let openTaskForm = Notification.Name("openTaskForm")
    static let openTaskCreateForm = Notification.Name("openTaskCreateForm")
    static let openBlockEditor = Notification.Name("openBlockEditor")
    static let blockWriteFailed = Notification.Name("blockWriteFailed")
}
