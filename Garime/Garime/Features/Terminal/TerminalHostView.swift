import SwiftUI
import SwiftTerm

struct TerminalHostView: UIViewRepresentable {
    let viewModel: TerminalViewModel
    @Binding var fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    static func applyColors(_ term: TerminalView, dark: Bool) {
        term.nativeForegroundColor = dark ? .white : .black
        term.nativeBackgroundColor = dark ? .black : .white
        term.caretColor = dark ? .white : .black
    }

    func makeUIView(context: Context) -> TerminalView {
        let term = GeoTerminalView(frame: .zero)
        term.terminalDelegate = context.coordinator
        term.font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        term.backgroundColor = .systemBackground
        term.allowMouseReporting = true
        term.isAccessibilityElement = true
        term.accessibilityIdentifier = "terminal.surface"
        let dark = context.environment.colorScheme == .dark
        context.coordinator.isDark = dark
        Self.applyColors(term, dark: dark)
        context.coordinator.terminal = term
        term.onSend = { bytes in
            MainActor.assumeIsolated { viewModel.send(bytes) }
        }

        for existing in term.gestureRecognizers ?? [] {
            if let tap = existing as? UITapGestureRecognizer, tap.numberOfTapsRequired >= 2 {
                tap.isEnabled = false
                context.coordinator.nativeSelectionGestures.append(tap)
            }
            if existing is UILongPressGestureRecognizer {
                existing.isEnabled = false
                context.coordinator.nativeSelectionGestures.append(existing)
            }
        }

        let scroll = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleScrollPan(_:))
        )
        scroll.minimumNumberOfTouches = 1
        scroll.maximumNumberOfTouches = 1
        scroll.delegate = context.coordinator
        term.addGestureRecognizer(scroll)
        context.coordinator.scrollPan = scroll

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        term.addGestureRecognizer(doubleTap)

        let cursorPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleCursorPress(_:))
        )
        cursorPress.minimumPressDuration = 0.35
        cursorPress.allowableMovement = .greatestFiniteMagnitude
        cursorPress.delegate = context.coordinator
        term.addGestureRecognizer(cursorPress)
        context.coordinator.customGestures = [scroll, doubleTap, cursorPress]

        let selectionTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleSelectionTap(_:))
        )
        selectionTap.numberOfTouchesRequired = 2
        selectionTap.delegate = context.coordinator
        term.addGestureRecognizer(selectionTap)

        let overlay = Coordinator.makeCursorOverlay()
        term.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: term.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: term.centerYAnchor),
            overlay.widthAnchor.constraint(equalToConstant: 68),
            overlay.heightAnchor.constraint(equalToConstant: 32),
        ])
        context.coordinator.cursorOverlay = overlay

        viewModel.onBytes = { [weak term, weak coordinator = context.coordinator] bytes, replay in
            if replay { coordinator?.suppressResponses = true }
            term?.feed(byteArray: bytes[...])
            if replay { coordinator?.suppressResponses = false }
        }
        viewModel.onReset = { [weak term] in
            term?.feed(byteArray: Array("\u{1b}[3J\u{1b}[2J\u{1b}[H".utf8)[...])
        }
        viewModel.onToggleKeyboard = { [weak term] in
            guard let term else { return }
            if term.isFirstResponder {
                _ = term.resignFirstResponder()
            } else {
                _ = term.becomeFirstResponder()
            }
        }
        viewModel.onShowKeyboard = { [weak term] in
            guard let term, !term.isFirstResponder else { return }
            _ = term.becomeFirstResponder()
        }
        viewModel.onPaste = { [weak term] in
            term?.paste(nil)
        }
        viewModel.onCopySelection = { [weak coordinator = context.coordinator] in
            coordinator?.copySelection()
        }
        viewModel.onSelectionMode = { [weak coordinator = context.coordinator] on in
            coordinator?.applySelectionMode(on)
        }
        term.onPaste = { [weak term] in term?.paste(nil) }
        return term
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        let target = CGFloat(fontSize)
        if abs(uiView.font.pointSize - target) > 0.1 {
            uiView.font = UIFont.monospacedSystemFont(ofSize: target, weight: .regular)
        }
        let dark = context.environment.colorScheme == .dark
        if context.coordinator.isDark != dark {
            context.coordinator.isDark = dark
            Self.applyColors(uiView, dark: dark)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        let viewModel: TerminalViewModel
        weak var terminal: TerminalView?
        weak var cursorOverlay: UIView?
        var isDark = true
        var suppressResponses = false
        var nativeSelectionGestures: [UIGestureRecognizer] = []
        var customGestures: [UIGestureRecognizer] = []
        weak var scrollPan: UIPanGestureRecognizer?
        private var scrollAccum: CGFloat = 0
        private let scrollStep: CGFloat = 14
        private var cursorActive = false
        private var cursorAnchor: CGPoint = .zero
        private let cursorStep: CGFloat = 12
        private let haptic = UIImpactFeedbackGenerator(style: .light)

        init(viewModel: TerminalViewModel) { self.viewModel = viewModel }

        static func makeCursorOverlay() -> UIView {
            let label = UILabel()
            label.text = "◂ ▸"
            label.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
            label.textColor = SlatePalette.text
            label.backgroundColor = SlatePalette.card
            label.textAlignment = .center
            label.layer.cornerRadius = 8
            label.layer.cornerCurve = .continuous
            label.layer.borderWidth = 1
            label.layer.borderColor = SlatePalette.stroke.cgColor
            label.clipsToBounds = true
            label.alpha = 0
            label.isUserInteractionEnabled = false
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }

        @objc func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
            guard !cursorActive else {
                gesture.setTranslation(.zero, in: gesture.view)
                return
            }
            switch gesture.state {
            case .began:
                scrollAccum = 0
            case .changed:
                let translation = gesture.translation(in: gesture.view)
                gesture.setTranslation(.zero, in: gesture.view)
                scrollAccum += translation.y
                var up = 0
                while scrollAccum >= scrollStep { scrollAccum -= scrollStep; up += 1 }
                var down = 0
                while scrollAccum <= -scrollStep { scrollAccum += scrollStep; down += 1 }
                if up > 0 { sendWheel(up: true, count: up) }
                if down > 0 { sendWheel(up: false, count: down) }
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            MainActor.assumeIsolated { viewModel.send([0x09]) }
        }

        @objc func handleSelectionTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            haptic.impactOccurred()
            MainActor.assumeIsolated { viewModel.setSelectionMode(!viewModel.selectionMode) }
        }

        func applySelectionMode(_ on: Bool) {
            guard let terminal else { return }
            terminal.allowMouseReporting = !on
            for gesture in nativeSelectionGestures { gesture.isEnabled = on }
            for gesture in customGestures { gesture.isEnabled = !on }
            for gesture in terminal.gestureRecognizers ?? [] where gesture is UIPanGestureRecognizer {
                guard gesture !== scrollPan else { continue }
                gesture.isEnabled = on
            }
            if !on {
                terminal.selectNone()
                UIMenuController.shared.hideMenu()
            }
            terminal.layer.borderWidth = on ? 1 : 0
            terminal.layer.borderColor = on ? SlatePalette.stroke.cgColor : nil
            terminal.setNeedsDisplay()
        }

        func copySelection() {
            guard let terminal, let text = terminal.getSelection(), !text.isEmpty else { return }
            UIPasteboard.general.string = text
            terminal.selectNone()
            terminal.setNeedsDisplay()
        }

        @objc func handleCursorPress(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                cursorActive = true
                cursorAnchor = gesture.location(in: gesture.view)
                haptic.impactOccurred()
                setCursorOverlay(visible: true)
            case .changed:
                guard cursorActive else { return }
                let point = gesture.location(in: gesture.view)
                let dx = point.x - cursorAnchor.x
                let dy = point.y - cursorAnchor.y
                let steps = Int(dx / cursorStep)
                if steps != 0 {
                    cursorAnchor.x += CGFloat(steps) * cursorStep
                    sendArrow(steps > 0 ? "C" : "D", count: abs(steps))
                }
                let vSteps = Int(dy / cursorStep)
                if vSteps != 0 {
                    cursorAnchor.y += CGFloat(vSteps) * cursorStep
                    sendArrow(vSteps > 0 ? "B" : "A", count: abs(vSteps))
                }
            default:
                guard cursorActive else { return }
                cursorActive = false
                setCursorOverlay(visible: false)
            }
        }

        private func setCursorOverlay(visible: Bool) {
            guard let cursorOverlay else { return }
            cursorOverlay.superview?.bringSubviewToFront(cursorOverlay)
            UIView.animate(withDuration: 0.12) { cursorOverlay.alpha = visible ? 1 : 0 }
        }

        private func sendArrow(_ direction: String, count: Int) {
            let applicationCursor = terminal?.getTerminal().applicationCursor ?? false
            let prefix = applicationCursor ? "\u{1b}O" : "\u{1b}["
            let seq = String(repeating: prefix + direction, count: min(count, 8))
            MainActor.assumeIsolated { viewModel.send(Array(seq.utf8)) }
        }

        private func sendWheel(up: Bool, count: Int) {
            let one = up ? "\u{1b}[<64;1;1M" : "\u{1b}[<65;1;1M"
            let seq = String(repeating: one, count: min(count, 8))
            MainActor.assumeIsolated { viewModel.send(Array(seq.utf8)) }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard !suppressResponses else { return }
            let bytes = (source as? GeoTerminalView)?.applyPendingModifiers(Array(data)) ?? Array(data)
            MainActor.assumeIsolated {
                viewModel.setSelectionMode(false)
                viewModel.send(bytes)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { viewModel.updateSize(rows: newRows, cols: newCols) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8), !text.isEmpty else { return }
            UIPasteboard.general.string = text
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
