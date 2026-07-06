import SwiftUI
import SwiftTerm

struct TerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    @StateObject private var viewModel = TerminalViewModel(session: "mobile")
    @AppStorage("terminal.fontSize") private var fontSize: Double = 10
    @AppStorage("terminal.sessions") private var sessionsRaw = "mobile"

    private var sessions: [String] {
        let list = sessionsRaw.split(separator: ",").map(String.init)
        return list.isEmpty ? ["mobile"] : list
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalHostView(viewModel: viewModel, fontSize: fontSize)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { viewModel.connect() }
        .onDisappear { viewModel.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if wasBackgrounded {
                    wasBackgrounded = false
                    viewModel.reconnect()
                }
            case .background:
                wasBackgrounded = true
                viewModel.disconnect()
            default:
                break
            }
        }
        .onChange(of: viewModel.connected) { _, connected in
            guard connected else { return }
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await fitRemote(force: false)
            }
        }
    }

    private func fitRemote(force: Bool) async {
        guard viewModel.connected, let ws = await viewModel.fetchWinsize(), force || ws.shared else { return }
        let ratio = min(Double(viewModel.cols) / Double(ws.cols), Double(viewModel.rows) / Double(ws.rows))
        guard ratio > 0.05, abs(ratio - 1) > 0.02 else { return }
        fontSize = clampFont(fontSize * ratio)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sessions, id: \.self) { sessionChip($0) }
                    Button { addSession() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                }
                .padding(.vertical, 2)
            }
            Button { viewModel.onToggleKeyboard?() } label: {
                Image(systemName: "keyboard").font(.system(size: 15, weight: .semibold))
            }
            Menu {
                Button { Task { await fitRemote(force: true) } } label: { Label("Fit remote", systemImage: "arrow.up.left.and.arrow.down.right") }
                Button { fitToWidth() } label: { Label("Fit width", systemImage: "arrow.left.and.right.square") }
                Button { fontSize = clampFont(fontSize + 1) } label: { Label("Larger", systemImage: "textformat.size.larger") }
                Button { fontSize = clampFont(fontSize - 1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                Button { viewModel.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
            }
            if viewModel.reconnecting {
                Text("reconnecting…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
            Circle()
                .fill(viewModel.connected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .systemBackground))
    }

    private func sessionChip(_ name: String) -> some View {
        let active = name == viewModel.session
        return HStack(spacing: 5) {
            Text(name)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            if sessions.count > 1 {
                Button { closeSession(name) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.55))
        .background(active ? Color.primary.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().stroke(active ? Color.green.opacity(0.7) : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { viewModel.switchTo(name) }
    }

    private func clampFont(_ v: Double) -> Double { min(24, max(7, v)) }

    private func fitToWidth() {
        fontSize = clampFont(fontSize * Double(max(1, viewModel.cols)) / 80.0)
    }

    private func addSession() {
        let existing = Set(sessions)
        var name = "mobile"
        var i = 2
        while existing.contains(name) { name = "mobile\(i)"; i += 1 }
        sessionsRaw = (sessions + [name]).joined(separator: ",")
        viewModel.switchTo(name)
    }

    private func closeSession(_ name: String) {
        var list = sessions.filter { $0 != name }
        if list.isEmpty { list = ["mobile"] }
        sessionsRaw = list.joined(separator: ",")
        killSession(name)
        if viewModel.session == name {
            viewModel.switchTo(list.first ?? "mobile")
        }
    }

    private func killSession(_ name: String) {
        Task {
            _ = try? await BridgeClient.shared.postData(
                "/term/kill?session=\(name)", token: BridgeConfig.termToken
            )
        }
    }
}

final class GeoTerminalView: TerminalView {
    override func mouseModeChanged(source: Terminal) {}
}

struct TerminalHostView: UIViewRepresentable {
    let viewModel: TerminalViewModel
    var fontSize: Double

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
        let dark = context.environment.colorScheme == .dark
        context.coordinator.isDark = dark
        Self.applyColors(term, dark: dark)
        context.coordinator.terminal = term

        let scroll = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleScrollPan(_:))
        )
        scroll.minimumNumberOfTouches = 1
        scroll.maximumNumberOfTouches = 1
        scroll.delegate = context.coordinator
        term.addGestureRecognizer(scroll)

        viewModel.onBytes = { [weak term] bytes in
            term?.feed(byteArray: bytes[...])
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
        var isDark = true
        private var scrollAccum: CGFloat = 0
        private let scrollStep: CGFloat = 14

        init(viewModel: TerminalViewModel) { self.viewModel = viewModel }

        @objc func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
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
            MainActor.assumeIsolated { viewModel.send(Array(data)) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { viewModel.updateSize(rows: newRows, cols: newCols) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
