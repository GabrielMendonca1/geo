import AppKit
import SwiftUI

struct FloatingToolbarContent: View {
    let formatting: ActiveFormattingState
    let onBold: () -> Void
    let onItalic: () -> Void
    let onStrikethrough: () -> Void
    let onCode: () -> Void
    let onHighlight: () -> Void
    let onLink: () -> Void
    let onTurnInto: (EditorBlockKind) -> Void

    var body: some View {
        HStack(spacing: 2) {
            toolbarButton("bold", label: "Bold", active: formatting.isBold, action: onBold)
            toolbarButton("italic", label: "Italic", active: formatting.isItalic, action: onItalic)
            toolbarButton("strikethrough", label: "Strikethrough", active: formatting.isStrikethrough, action: onStrikethrough)
            toolbarButton("chevron.left.forwardslash.chevron.right", label: "Code", active: formatting.isCode, action: onCode)
            toolbarButton("highlighter", label: "Highlight", active: formatting.isHighlight, action: onHighlight)

            Divider().frame(height: 20).accessibilityHidden(true)

            toolbarButton("link", label: "Link", active: false, action: onLink)

            Divider().frame(height: 20).accessibilityHidden(true)

            turnIntoMenu
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private func toolbarButton(_ icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: active ? .bold : .regular))
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.7))
                .frame(width: 28, height: 28)
                .background(active ? Color.accentColor.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var turnIntoMenu: some View {
        Menu {
            Button("Paragraph") { onTurnInto(.paragraph) }
            Divider()
            Button("Heading 1") { onTurnInto(.heading(level: 1)) }
            Button("Heading 2") { onTurnInto(.heading(level: 2)) }
            Button("Heading 3") { onTurnInto(.heading(level: 3)) }
            Divider()
            Button("Bullet List") { onTurnInto(.bulletItem(marker: "-")) }
            Button("Numbered List") { onTurnInto(.orderedItem(number: 1)) }
            Button("To-do") { onTurnInto(.checkboxItem(checked: false, marker: "-")) }
            Divider()
            Button("Quote") { onTurnInto(.blockquote) }
        } label: {
            HStack(spacing: 3) {
                Text("Turn into")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.primary.opacity(0.7))
            .padding(.horizontal, 6)
            .frame(height: 28)
        }
        .buttonStyle(.plain)
    }
}

final class FloatingToolbarPanel {
    private var panel: NSPanel?
    private weak var textView: BlockNSTextView?
    private var hostingView: NSHostingView<FloatingToolbarContent>?
    private var windowObservers: [NSObjectProtocol] = []

    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?
    var onStrikethrough: (() -> Void)?
    var onCode: (() -> Void)?
    var onHighlight: (() -> Void)?
    var onLink: (() -> Void)?
    var onTurnInto: ((EditorBlockKind) -> Void)?

    deinit {
        removeObservers()
    }

    func show(above rect: NSRect, in textView: BlockNSTextView, formatting: ActiveFormattingState) {
        self.textView = textView

        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: true
            )
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hidesOnDeactivate = true
            p.becomesKeyOnlyIfNeeded = true
            p.hasShadow = false
            p.isMovableByWindowBackground = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
        }

        removeObservers()
        if let parentWindow = textView.window {
            let resign = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                self?.dismiss()
            }
            windowObservers.append(resign)
        }

        updateContent(formatting: formatting)
        updatePosition(above: rect, in: textView)
        panel?.orderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        removeObservers()
    }

    private func removeObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    func updatePosition(above rect: NSRect, in textView: BlockNSTextView) {
        guard let panel, let window = textView.window else { return }

        let viewRect = textView.convert(rect, to: nil)
        let screenRect = window.convertToScreen(NSRect(origin: viewRect.origin, size: viewRect.size))

        let panelSize = panel.frame.size
        let x = screenRect.midX - panelSize.width / 2
        let y = screenRect.maxY + 6

        var origin = NSPoint(x: x, y: y)

        if let screen = window.screen {
            let screenFrame = screen.visibleFrame
            origin.x = max(screenFrame.minX + 4, min(origin.x, screenFrame.maxX - panelSize.width - 4))
            if origin.y + panelSize.height > screenFrame.maxY {
                origin.y = screenRect.minY - panelSize.height - 6
            }
        }

        panel.setFrameOrigin(origin)
    }

    func updateFormatting(_ state: ActiveFormattingState) {
        updateContent(formatting: state)
    }

    private func updateContent(formatting: ActiveFormattingState) {
        let content = FloatingToolbarContent(
            formatting: formatting,
            onBold: { [weak self] in self?.onBold?() },
            onItalic: { [weak self] in self?.onItalic?() },
            onStrikethrough: { [weak self] in self?.onStrikethrough?() },
            onCode: { [weak self] in self?.onCode?() },
            onHighlight: { [weak self] in self?.onHighlight?() },
            onLink: { [weak self] in self?.onLink?() },
            onTurnInto: { [weak self] kind in self?.onTurnInto?(kind) }
        )

        if let hostingView {
            hostingView.rootView = content
        } else {
            let hv = NSHostingView(rootView: content)
            hv.translatesAutoresizingMaskIntoConstraints = false
            panel?.contentView = hv
            hostingView = hv
        }

        hostingView?.invalidateIntrinsicContentSize()
        if let size = hostingView?.fittingSize {
            panel?.setContentSize(size)
        }
    }
}
