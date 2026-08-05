import PhotosUI
import SwiftUI

enum TerminalSessionList {
    static let reserved = "vm:mac"
    static let mac = "mac:mac"

    static func normalized(_ raw: String) -> [String] {
        let list = raw.split(separator: ",").map(String.init)
            .map { $0.contains(":") ? $0 : "vm:\($0)" }
            .filter { $0 != reserved }
        return list.isEmpty ? ["vm:mobile"] : list
    }

    static func homeList(_ raw: String) -> [String] {
        var seen = Set<String>()
        return (normalized(raw) + [mac]).filter { seen.insert($0).inserted }
    }

    static func origin(for name: String) -> String {
        name.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "vm"
    }

    static func label(for name: String) -> String {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[1] : name
    }

    static func endpoint(for name: String) -> String {
        origin(for: name) == "mac" ? "mac" : label(for: name)
    }

    static func isValidName(_ name: String) -> Bool {
        guard name != "mac", (1...32).contains(name.count) else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func renamed(raw: String, from: String, to: String) -> String {
        normalized(raw).map { $0 == from ? "vm:\(to)" : $0 }.joined(separator: ",")
    }
}

struct TerminalScreen: View {
    var onBack: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    @State private var terminalOrigin: String
    @State private var showSnips = CommandLine.arguments.contains("-geoSnips")
    @State private var showSessions = CommandLine.arguments.contains("-geoSessions")
    @StateObject private var viewModel: TerminalViewModel
    @AppStorage("terminal.fontSize") private var fontSize: Double = 12
    @AppStorage("terminal.sessions") private var sessionsRaw = "vm:mobile"
    @State private var serverSessions: [String] = []
    @State private var serverListLoaded = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?

    init(initialSession: String = "vm:mobile", onBack: @escaping () -> Void = {}) {
        self.onBack = onBack
        let origin = TerminalSessionList.origin(for: initialSession)
        _terminalOrigin = State(initialValue: origin)
        _viewModel = StateObject(wrappedValue: TerminalViewModel(session: initialSession, origin: origin))
    }

    private var sessions: [String] {
        TerminalSessionList.normalized(sessionsRaw)
    }

    var body: some View {
        ZStack(alignment: .top) {
            TerminalHostView(viewModel: viewModel, fontSize: $fontSize)
                .padding(.top, Self.headerHeight + 8)
                .ignoresSafeArea(.container, edges: .bottom)
            header
        }
        .sheet(isPresented: $showSnips) {
            SnipsSheet { text in viewModel.send(Array(text.utf8)) }
        }
        .sheet(isPresented: $showSessions) {
            SessionsSheet(
                sessions: sessions,
                current: viewModel.session,
                isDead: isDead,
                onSelect: selectSession,
                onSelectMac: { selectOrigin("mac") },
                onCreate: addSession,
                onDelete: closeSession,
                onRefresh: refreshServerSessions
            )
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            importFile(result)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await importPhoto(item) }
        }
        .onAppear {
            pruneReservedSessions()
            viewModel.connect()
            Task { await refreshServerSessions() }
            raiseKeyboard()
        }
        .onDisappear { viewModel.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if wasBackgrounded {
                    wasBackgrounded = false
                    viewModel.reconnect()
                    raiseKeyboard()
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
                await refreshServerSessions()
                try? await Task.sleep(nanoseconds: 600_000_000)
                await fitRemote(force: false)
            }
        }
    }

    private func raiseKeyboard() {
        guard !showSnips, !showSessions else { return }
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !showSnips, !showSessions else { return }
            viewModel.onShowKeyboard?()
        }
    }

    private func pruneReservedSessions() {
        let pruned = sessions.joined(separator: ",")
        guard pruned != sessionsRaw else { return }
        sessionsRaw = pruned
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            viewModel.flashUploadFailure()
            return
        }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        await viewModel.upload(data, filename: "foto-\(Self.stamp()).\(ext)")
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            viewModel.flashUploadFailure()
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            viewModel.flashUploadFailure()
            return
        }
        let name = UploadName.sanitized(url.lastPathComponent, fallback: "arquivo-\(Self.stamp())")
        Task { await viewModel.upload(data, filename: name) }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func refreshServerSessions() async {
        guard let fetched = await viewModel.fetchSessions() else { return }
        let list = fetched.filter { $0 != "mac" }
        serverSessions = list
        serverListLoaded = true
        let known = Set(sessions)
        let extras = list.map { "vm:\($0)" }.filter { !known.contains($0) }
        guard !extras.isEmpty else { return }
        sessionsRaw = (sessions + extras).joined(separator: ",")
    }

    private func isDead(_ name: String) -> Bool {
        guard serverListLoaded, name.hasPrefix("vm:") else { return false }
        return !serverSessions.contains(String(name.dropFirst(3)))
    }

    private func fitRemote(force: Bool) async {
        guard viewModel.connected, let ws = await viewModel.fetchWinsize(), force || ws.shared else { return }
        let ratio = min(Double(viewModel.cols) / Double(ws.cols), Double(viewModel.rows) / Double(ws.rows))
        guard ratio > 0.05, abs(ratio - 1) > 0.02 else { return }
        fontSize = clampFont(fontSize * ratio)
    }

    private static let headerHeight: CGFloat = 44

    private var header: some View {
        GlassChrome {
            HStack(spacing: 6) {
                Button { onBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassSurface(shape: Circle(), interactive: true)

                titleChip

                Spacer(minLength: 4)

                statusText

                trailingCluster
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 44)
        }
        .animation(.spring(response: 0.34, dampingFraction: 1), value: statusKey)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: viewModel.session)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: viewModel.connected)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: viewModel.selectionMode)
    }

    private var trailingCluster: some View {
        HStack(spacing: 0) {
            if viewModel.selectionMode {
                Button { viewModel.onCopySelection?() } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            Button { showSnips = true } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { viewModel.onToggleKeyboard?() } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button { viewModel.onPaste?() } label: { Label("colar", systemImage: "doc.on.clipboard") }
                Button { showPhotoPicker = true } label: { Label("enviar foto", systemImage: "photo") }
                Button { showFileImporter = true } label: { Label("enviar arquivo", systemImage: "doc") }
                Divider()
                Button { Task { await fitRemote(force: true) } } label: { Label("Fit remote", systemImage: "arrow.up.left.and.arrow.down.right") }
                Button { fitToWidth() } label: { Label("Fit width", systemImage: "arrow.left.and.right.square") }
                Button { fontSize = clampFont(fontSize + 1) } label: { Label("Larger", systemImage: "textformat.size.larger") }
                Button { fontSize = clampFont(fontSize - 1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                Button { viewModel.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            connectionDot
                .padding(.trailing, 12)
        }
        .foregroundStyle(.primary)
        .glassSurface(shape: Capsule(), interactive: false)
    }

    private var connectionDot: some View {
        StatusDot(level: .live(viewModel.connected))
    }

    private var titleChip: some View {
        let dead = isDead(viewModel.session)
        let selecting = viewModel.selectionMode
        return Button { showSessions = true } label: {
            HStack(spacing: 5) {
                Text(selecting ? "seleção" : viewModel.session)
                    .font(.system(size: 13, weight: selecting ? .semibold : .medium, design: .monospaced))
                    .lineLimit(1)
                    .opacity(dead && !selecting ? 0.45 : 1)
                Image(systemName: selecting ? "selection.pin.in.out" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSurface(shape: Capsule(), interactive: true)
    }

    private var statusKey: String {
        if let notice = viewModel.notice { return notice }
        if viewModel.reconnecting { return "reconnecting…" }
        if !viewModel.connected, let message = viewModel.errorMessage { return message }
        return ""
    }

    @ViewBuilder
    private var statusText: some View {
        if !statusKey.isEmpty {
            Text(statusKey)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private func clampFont(_ v: Double) -> Double { min(24, max(7, v)) }

    private func fitToWidth() {
        fontSize = clampFont(fontSize * Double(max(1, viewModel.cols)) / 80.0)
    }

    private func addSession() {
        let existing = Set(sessions)
        var name = "vm:mobile"
        var i = 2
        while existing.contains(name) || name == TerminalSessionList.reserved {
            name = "vm:mobile\(i)"
            i += 1
        }
        sessionsRaw = (sessions + [name]).joined(separator: ",")
        terminalOrigin = "vm"
        viewModel.switchTo(name, origin: "vm")
    }

    private func selectSession(_ name: String) {
        let origin = name.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "vm"
        terminalOrigin = origin
        viewModel.switchTo(name, origin: origin)
    }

    private func selectOrigin(_ origin: String) {
        terminalOrigin = origin
        if origin == "vm" { Task { await refreshServerSessions() } }
        let name = sessions.first { $0.hasPrefix("\(origin):") } ?? "\(origin):\(origin == "mac" ? "mac" : "mobile")"
        if !sessions.contains(name) {
            sessionsRaw = (sessions + [name]).joined(separator: ",")
        }
        viewModel.switchTo(name, origin: origin)
    }

    private func closeSession(_ name: String) {
        var list = sessions.filter { $0 != name }
        if list.isEmpty { list = ["vm:mobile"] }
        sessionsRaw = list.joined(separator: ",")
        viewModel.killSession(name)
        if viewModel.session == name {
            let next = list.first { $0.hasPrefix("\(terminalOrigin):") } ?? list[0]
            let origin = next.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "vm"
            terminalOrigin = origin
            viewModel.switchTo(next, origin: origin)
        }
    }
}
