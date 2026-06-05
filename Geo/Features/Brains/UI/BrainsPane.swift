import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - File-native model (~/Geo/Brains/<name>/ vaults are the source of truth)

struct BrainMeta: Codable {
    var id: String
    var title: String
    var gist: String
    var created: String?
    var updated: String?
    var nodes: Int?
    var sources: [String]?
}

struct BrainVault: Identifiable, Hashable {
    let id: String
    let title: String
    let gist: String
    let noteCount: Int
    let sourceCount: Int
    let folder: URL
    var ready: Bool { noteCount > 0 }
}

struct BrainNote: Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    let url: URL
}

// MARK: - Free-canvas board model (per-vault frame + zoom, persisted to UserDefaults)

struct BrainBoardLayout: Codable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat
    var zoom: CGFloat

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }

    static let minSize = CGSize(width: 220, height: 150)
    static func maxSize(in pane: CGSize) -> CGSize {
        CGSize(width: min(pane.width, 960), height: min(pane.height, 680))
    }
    static let zoomRange: ClosedRange<CGFloat> = 0.5...4.0
}

enum BrainBoardStore {
    private static func key(_ vaultId: String) -> String { "brains.board.\(vaultId)" }

    static func load(_ vaultId: String) -> BrainBoardLayout? {
        guard let data = UserDefaults.standard.data(forKey: key(vaultId)) else { return nil }
        return try? JSONDecoder().decode(BrainBoardLayout.self, from: data)
    }

    static func save(_ vaultId: String, _ layout: BrainBoardLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: key(vaultId))
    }
}

@MainActor
final class BrainBoardModel: ObservableObject {
    @Published var layouts: [String: BrainBoardLayout] = [:]

    func ensure(vaults: [BrainVault], pane: CGSize) {
        guard pane.width > 0, pane.height > 0 else { return }
        var missing: [BrainVault] = []
        for v in vaults where layouts[v.id] == nil {
            if let saved = BrainBoardStore.load(v.id) { layouts[v.id] = saved }
            else { missing.append(v) }
        }
        guard !missing.isEmpty else { return }
        let flowed = BrainBoardModel.autoFlow(missing, startIndex: layouts.count, pane: pane)
        for (id, layout) in flowed { layouts[id] = layout; BrainBoardStore.save(id, layout) }
    }

    func update(_ id: String, _ layout: BrainBoardLayout) { layouts[id] = layout }
    func commit(_ id: String) { if let l = layouts[id] { BrainBoardStore.save(id, l) } }

    static func autoFlow(_ vaults: [BrainVault], startIndex: Int, pane: CGSize) -> [(String, BrainBoardLayout)] {
        let gutter: CGFloat = 16, topInset: CGFloat = 64, side: CGFloat = 20
        let usableW = max(pane.width - side * 2, BrainBoardLayout.minSize.width)
        let cols = max(1, min(4, Int((usableW + gutter) / (340 + gutter))))
        let cardW = max(BrainBoardLayout.minSize.width, (usableW - gutter * CGFloat(cols - 1)) / CGFloat(cols))
        let cardH = max(BrainBoardLayout.minSize.height, cardW * 2.0 / 3.0)

        var out: [(String, BrainBoardLayout)] = []
        for (offset, v) in vaults.enumerated() {
            let i = startIndex + offset
            let col = i % cols, row = i / cols
            let x = side + CGFloat(col) * (cardW + gutter)
            let y = topInset + CGFloat(row) * (cardH + gutter)
            out.append((v.id, BrainBoardLayout(x: x, y: y, w: cardW, h: cardH, zoom: 1.0)))
        }
        return out
    }
}

@MainActor
final class BrainVaultStore: ObservableObject {
    @Published var vaults: [BrainVault] = []

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Geo/Brains", isDirectory: true)

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [BrainVault] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let meta = Self.meta(in: dir) else { continue }
            found.append(BrainVault(
                id: meta.id, title: meta.title, gist: meta.gist,
                noteCount: Self.noteFiles(in: dir).count,
                sourceCount: Self.sourceFiles(in: dir).count,
                folder: dir
            ))
        }
        vaults = found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    nonisolated static func meta(in folder: URL) -> BrainMeta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".brain.json")) else { return nil }
        return try? JSONDecoder().decode(BrainMeta.self, from: data)
    }

    nonisolated static func noteFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "index.md" }
    }

    nonisolated static func sourceFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("sources"), includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
    }

    nonisolated static func notes(in vault: BrainVault) -> [BrainNote] {
        noteFiles(in: vault.folder).compactMap { url in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let body = stripFrontmatter(raw)
            return BrainNote(id: url.deletingPathExtension().lastPathComponent, title: titleOf(body, fallback: url.deletingPathExtension().lastPathComponent), body: body, url: url)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    func create(name: String, gist: String) throws -> BrainVault {
        let id = Self.slug(name)
        let dir = Self.root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sources"), withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter().string(from: Date())
        try writeMeta(BrainMeta(id: id, title: name, gist: gist, created: iso, updated: iso, nodes: 0, sources: []), to: dir)
        VaultIngest.rebuildIndex(in: dir, title: name, gist: gist)
        reload()
        return vaults.first { $0.id == id } ?? BrainVault(id: id, title: name, gist: gist, noteCount: 0, sourceCount: 0, folder: dir)
    }

    nonisolated static func slug(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        return String(lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }).split(separator: "-").joined(separator: "-")
    }
}

private func writeMeta(_ meta: BrainMeta, to folder: URL) throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(meta).write(to: folder.appendingPathComponent(".brain.json"))
}

private func stripFrontmatter(_ raw: String) -> String {
    guard raw.hasPrefix("---") else { return raw }
    let lines = raw.components(separatedBy: "\n")
    var idx = 1
    while idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces) != "---" { idx += 1 }
    return lines.dropFirst(idx + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func titleOf(_ body: String, fallback: String) -> String {
    for line in body.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { return String(t.drop(while: { $0 == "#" }).drop(while: { $0 == " " })) }
    }
    return fallback
}

// MARK: - In-app ingest (delegates to the brain.py CLI → Claude Code account, no API key)

enum VaultIngestError: LocalizedError {
    case cliMissing
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .cliMissing: return "brain.py isn't bundled. Set the UserDefaults key 'BrainCLIPath' to the script path."
        case .failed(let message): return message.isEmpty ? "Ingest failed." : message
        }
    }
}

enum VaultIngest {
    @discardableResult
    static func ingest(folder: URL, sources: [String] = []) async throws -> Int {
        guard let script = scriptURL() else { throw VaultIngestError.cliMissing }
        let before = BrainVaultStore.noteFiles(in: folder).count
        let process = Process()
        // Pin to the system interpreter (3.9.6) — `env python3` can resolve to a brew 3.x
        // with different behavior; the stdlib-only script needs nothing else.
        let pinned = "/usr/bin/python3"
        let usePinned = FileManager.default.isExecutableFile(atPath: pinned)
        process.executableURL = URL(fileURLWithPath: usePinned ? pinned : "/usr/bin/env")
        var args: [String] = usePinned ? [] : ["python3"]
        args += [script.path, "ingest", folder.lastPathComponent] + sources
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GEO_BRAINS_ROOT"] = folder.deletingLastPathComponent().path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in cont.resume() }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw VaultIngestError.failed(output.split(separator: "\n").last.map(String.init) ?? output)
        }
        return max(0, BrainVaultStore.noteFiles(in: folder).count - before)
    }

    static func rebuildIndex(in folder: URL, title: String, gist: String) {
        let notes = BrainVaultStore.noteFiles(in: folder).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines = ["# \(title)", ""]
        if !gist.isEmpty { lines += [gist, ""] }
        lines += ["## Notes (\(notes.count))", ""] + notes.map { "- [[\($0.deletingPathExtension().lastPathComponent)]]" }
        try? (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        if var meta = BrainVaultStore.meta(in: folder) {
            meta.nodes = notes.count
            meta.sources = BrainVaultStore.sourceFiles(in: folder).map { $0.lastPathComponent }
            meta.updated = ISO8601DateFormatter().string(from: Date())
            try? writeMeta(meta, to: folder)
        }
    }

    private static func scriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "brain", withExtension: "py") { return bundled }
        if let override = UserDefaults.standard.string(forKey: "BrainCLIPath"), FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        return nil
    }
}

// MARK: - Pane (in-pane navigation — no NavigationStack; this window has a hidden title bar)

struct BrainsPane: View {
    @StateObject private var store = BrainVaultStore()
    @StateObject private var board = BrainBoardModel()
    @State private var showCreate = false
    @State private var openVaultId: String?
    @State private var paneSize: CGSize = .zero

    var body: some View {
        Pane {
            Group {
                if let id = openVaultId, let vault = store.vaults.first(where: { $0.id == id }) {
                    BrainDetailView(vault: vault, onBack: { openVaultId = nil; store.reload() })
                } else {
                    boardView
                }
            }
        }
        .sheet(isPresented: $showCreate) { CreateBrainSheet(store: store) { openVaultId = $0 } }
        .task { store.reload() }
    }

    private var boardView: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear

                if store.vaults.isEmpty {
                    emptyState
                } else {
                    ForEach(store.vaults) { vault in
                        if board.layouts[vault.id] != nil {
                            BrainBoardCard(
                                vault: vault,
                                layout: Binding(
                                    get: { board.layouts[vault.id]! },
                                    set: { board.update(vault.id, $0) }
                                ),
                                paneSize: geo.size,
                                onOpen: { openVaultId = vault.id },
                                onCommit: { board.commit(vault.id) }
                            )
                        }
                    }
                }

                FloatingChrome(count: store.vaults.count,
                               onReveal: { NSWorkspace.shared.open(BrainVaultStore.root) },
                               onCreate: { showCreate = true })
            }
            .coordinateSpace(name: "board")
            .onAppear { paneSize = geo.size; board.ensure(vaults: store.vaults, pane: geo.size) }
            .onChange(of: geo.size) { _, s in paneSize = s; board.ensure(vaults: store.vaults, pane: s) }
            .onChange(of: store.vaults.map(\.id)) { _, _ in board.ensure(vaults: store.vaults, pane: geo.size) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain.head.profile").font(.system(size: 44, weight: .thin)).foregroundStyle(Palette.tertiaryForeground.opacity(0.55))
            Text("No brains yet").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.foreground)
            Text("Create a vault and attach sources — or build one from the terminal:").font(.system(size: 12)).foregroundStyle(Palette.tertiaryForeground)
            Text("brain ingest <name> <files…>").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.foreground.opacity(0.7))
                .padding(.horizontal, 10).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Palette.agentCard)))
            Button { showCreate = true } label: { Label("New Brain", systemImage: "plus") }.buttonStyle(PillButtonStyle()).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Reusable controls

private struct IconButton: View {
    let system: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 13))
                .foregroundStyle(hover ? Palette.foreground : Palette.tertiaryForeground)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Palette.foreground.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Capsule().fill(Palette.foreground.opacity(configuration.isPressed ? 0.82 : 1)))
            .foregroundStyle(Palette.background)
    }
}

// A kind glyph inside a soft tinted chip — shared by source rows and add tiles.
private struct SourceBadge: View {
    let kind: BrainSourceKind
    var size: CGFloat = 40
    var corner: CGFloat = 10
    var glyph: CGFloat = 18

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(kind.tint.opacity(0.14))
            Image(systemName: kind.icon).font(.system(size: glyph, weight: .regular)).foregroundStyle(kind.tint)
        }
        .frame(width: size, height: size)
    }
}

private struct RebuildButton: View {
    var spinning: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover ? Palette.foreground : Palette.tertiaryForeground)
                .rotationEffect(.degrees(angle))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Palette.foreground.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain).help("Rebuild notes from sources").onHover { hover = $0 }
        .onChange(of: spinning) { _, on in
            if on { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 } }
            else { withAnimation(.easeOut(duration: 0.2)) { angle = 0 } }
        }
    }
}

// MARK: - Floating chrome (translucent pills over the board)

private struct FloatingChrome: View {
    let count: Int
    let onReveal: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                titlePill
                Spacer()
                actionPill
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var titlePill: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Brains").font(.system(size: 18, weight: .bold)).foregroundStyle(Palette.foreground)
            Text("\(count) vault\(count == 1 ? "" : "s") · ~/Geo/Brains")
                .font(.system(size: 10.5)).foregroundStyle(Palette.tertiaryForeground)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Palette.foreground.opacity(0.10), lineWidth: 1))
        .allowsHitTesting(false)
    }

    private var actionPill: some View {
        HStack(spacing: 8) {
            IconButton(system: "folder", help: "Reveal ~/Geo/Brains in Finder", action: onReveal)
            Button(action: onCreate) { Label("New Brain", systemImage: "plus") }.buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Palette.foreground.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Board card (an Obsidian-style graph tile; resizable + movable + zoomable)

private enum Handle: CaseIterable {
    case top, bottom, leading, trailing
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var unit: CGPoint {
        switch self {
        case .top: return .init(x: 0.5, y: 0)
        case .bottom: return .init(x: 0.5, y: 1)
        case .leading: return .init(x: 0, y: 0.5)
        case .trailing: return .init(x: 1, y: 0.5)
        case .topLeading: return .init(x: 0, y: 0)
        case .topTrailing: return .init(x: 1, y: 0)
        case .bottomLeading: return .init(x: 0, y: 1)
        case .bottomTrailing: return .init(x: 1, y: 1)
        }
    }
    var movesLeft: Bool { unit.x == 0 }
    var movesRight: Bool { unit.x == 1 }
    var movesTop: Bool { unit.y == 0 }
    var movesBottom: Bool { unit.y == 1 }

    var cursor: NSCursor {
        switch self {
        case .leading, .trailing: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }
}

private struct ResizeHandleLayer: View {
    let visible: Bool
    let gestureFor: (Handle) -> AnyGesture<Void>

    private let hit: CGFloat = 18
    private let dot: CGFloat = 9
    private let ordered: [Handle] = [.top, .bottom, .leading, .trailing,
                                     .topLeading, .topTrailing, .bottomLeading, .bottomTrailing]

    var body: some View {
        GeometryReader { geo in
            ForEach(ordered, id: \.self) { h in
                Circle()
                    .fill(Color(nsColor: Palette.agentCardElevated))
                    .overlay(Circle().strokeBorder(Palette.foreground.opacity(0.55), lineWidth: 1.5))
                    .frame(width: dot, height: dot)
                    .opacity(visible ? 1 : 0)
                    .frame(width: hit, height: hit)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { h.cursor.push() } else { NSCursor.pop() } }
                    .gesture(gestureFor(h))
                    .position(x: geo.size.width * h.unit.x, y: geo.size.height * h.unit.y)
            }
        }
    }
}

private struct BrainBoardCard: View {
    let vault: BrainVault
    @Binding var layout: BrainBoardLayout
    let paneSize: CGSize
    let onOpen: () -> Void
    let onCommit: () -> Void

    @State private var hover = false
    @State private var liveFrame: CGRect?
    @State private var dragStartFrame: CGRect?
    @State private var moveStartOrigin: CGPoint?
    @State private var didDrag = false

    private let corner: CGFloat = 18
    private let tapSlop: CGFloat = 4

    private var frame: CGRect { liveFrame ?? layout.frame }

    var body: some View {
        cardSurface
            .frame(width: frame.width, height: frame.height)
            .overlay(alignment: .topLeading) { nameChip }
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay {
                ResizeHandleLayer(visible: hover, gestureFor: { h in AnyGesture(resizeGesture(h).map { _ in () }) })
            }
            .overlay(RoundedRectangle(cornerRadius: corner)
                .strokeBorder(hover ? Palette.foreground.opacity(0.28) : Palette.foreground.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(hover ? 0.16 : 0), radius: hover ? 14 : 0, y: hover ? 6 : 0)
            .position(x: frame.midX, y: frame.midY)
            .onHover { hover = $0 }
    }

    private var cardSurface: some View {
        ZStack {
            if vault.noteCount == 0 { EmptyGraphMotif() }
            else { BrainMiniGraph(vault: vault, zoom: $layout.zoom, onZoomCommit: onCommit) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: hover ? Palette.agentCardElevated : Palette.agentCard))
        .contentShape(Rectangle())
        .gesture(moveOrTap)
    }

    private var nameChip: some View {
        HStack(spacing: 6) {
            Circle().fill(vault.ready ? Color(nsColor: Palette.agentSuccess) : Palette.tertiaryForeground)
                .frame(width: 6, height: 6)
            Text(vault.title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.foreground).lineLimit(1)
            Text(countLabel).font(.system(size: 10))
                .foregroundStyle(Palette.tertiaryForeground).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Palette.foreground.opacity(0.10), lineWidth: 1))
        .padding(10)
        .allowsHitTesting(false)
    }

    private func resizeGesture(_ h: Handle) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("board"))
            .onChanged { value in
                let start = dragStartFrame ?? frame
                if dragStartFrame == nil { dragStartFrame = start }
                var r = start
                let dx = value.translation.width, dy = value.translation.height
                if h.movesLeft  { r.origin.x = start.minX + dx; r.size.width  = start.maxX - r.origin.x }
                if h.movesRight { r.size.width  = start.width  + dx }
                if h.movesTop   { r.origin.y = start.minY + dy; r.size.height = start.maxY - r.origin.y }
                if h.movesBottom { r.size.height = start.height + dy }
                liveFrame = clampAnchored(r, anchor: h, start: start)
            }
            .onEnded { _ in
                if let f = liveFrame { layout.frame = f }
                dragStartFrame = nil; liveFrame = nil; onCommit()
            }
    }

    private func clampAnchored(_ rect: CGRect, anchor h: Handle, start: CGRect) -> CGRect {
        let maxS = BrainBoardLayout.maxSize(in: paneSize)
        var r = rect
        let w = min(max(r.width,  BrainBoardLayout.minSize.width),  maxS.width)
        let hg = min(max(r.height, BrainBoardLayout.minSize.height), maxS.height)
        if h.movesLeft { r.origin.x = start.maxX - w } else { r.origin.x = start.minX }
        if h.movesTop  { r.origin.y = start.maxY - hg } else { r.origin.y = start.minY }
        r.size = CGSize(width: w, height: hg)
        return r
    }

    private var moveOrTap: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("board"))
            .onChanged { value in
                if moveStartOrigin == nil { moveStartOrigin = frame.origin }
                if hypot(value.translation.width, value.translation.height) > tapSlop { didDrag = true }
                guard didDrag, let o = moveStartOrigin else { return }
                var r = frame
                r.origin = clampOrigin(CGPoint(x: o.x + value.translation.width, y: o.y + value.translation.height), size: r.size)
                liveFrame = r
            }
            .onEnded { value in
                let dist = hypot(value.translation.width, value.translation.height)
                if !didDrag && dist <= tapSlop { onOpen() }
                else { if let f = liveFrame { layout.frame = f }; onCommit() }
                liveFrame = nil; moveStartOrigin = nil; didDrag = false
            }
    }

    private func clampOrigin(_ origin: CGPoint, size: CGSize) -> CGPoint {
        let margin: CGFloat = 12, topInset: CGFloat = 64, minVisible: CGFloat = 60
        let x = min(max(origin.x, margin - size.width + minVisible), max(margin, paneSize.width - minVisible))
        let y = min(max(origin.y, topInset), max(topInset, paneSize.height - minVisible))
        return CGPoint(x: x, y: y)
    }

    private var countLabel: String {
        let notes = "\(vault.noteCount) note\(vault.noteCount == 1 ? "" : "s")"
        guard vault.sourceCount > 0 else { return notes }
        return "\(notes) · \(vault.sourceCount) source\(vault.sourceCount == 1 ? "" : "s")"
    }
}

// Tasteful empty-brain state — a faint constellation of dim nodes, not a placeholder glyph.
private struct EmptyGraphMotif: View {
    var body: some View {
        Canvas { ctx, size in
            let golden = Double.pi * (3 - 5.0.squareRoot())
            let cx = size.width / 2, cy = size.height / 2
            let span = min(size.width, size.height) * 0.34
            var pts: [CGPoint] = []
            for i in 0..<7 {
                let radius = (Double(i) / 7).squareRoot() * span
                let theta = Double(i) * golden
                pts.append(CGPoint(x: cx + CGFloat(cos(theta)) * CGFloat(radius), y: cy + CGFloat(sin(theta)) * CGFloat(radius)))
            }
            for i in 1..<pts.count {
                var p = Path(); p.move(to: pts[0]); p.addLine(to: pts[i])
                ctx.stroke(p, with: .color(Palette.foreground.opacity(0.08)), lineWidth: 0.8)
            }
            for (i, c) in pts.enumerated() {
                let r: CGFloat = i == 0 ? 4 : 2.6
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Palette.foreground.opacity(0.16)))
            }
        }
        .overlay(alignment: .center) {
            Text("empty")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.tertiaryForeground.opacity(0.7))
                .offset(y: 30)
        }
    }
}

// MARK: - Mini-graph thumbnail (settled once, non-interactive — ports GraphView's force layout)

private struct ScrollZoomCatcher: NSViewRepresentable {
    var onZoom: (CGFloat) -> Void
    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.onZoom = onZoom; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.onZoom = onZoom }

    final class CatcherView: NSView {
        var onZoom: ((CGFloat) -> Void)?
        override func scrollWheel(with e: NSEvent) {
            let raw = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.deltaY
            guard raw != 0 else { super.scrollWheel(with: e); return }
            onZoom?(exp(raw * 0.01))
        }
        override func magnify(with e: NSEvent) { onZoom?(1 + e.magnification) }
        override func mouseDown(with e: NSEvent) { nextResponder?.mouseDown(with: e) }
        override func mouseDragged(with e: NSEvent) { nextResponder?.mouseDragged(with: e) }
        override func mouseUp(with e: NSEvent) { nextResponder?.mouseUp(with: e) }
    }
}

private struct BrainMiniGraph: View {
    let vault: BrainVault
    @Binding var zoom: CGFloat
    var onZoomCommit: () -> Void

    @State private var graph: BlockGraph = .empty
    @State private var layout = MiniGraphLayout.empty
    @State private var pinchBase: CGFloat = 0

    var body: some View {
        Canvas { ctx, size in draw(ctx, size) }
            .padding(10)
            .overlay(ScrollZoomCatcher { factor in applyZoom(factor) })
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        if pinchBase == 0 { pinchBase = zoom }
                        zoom = clampZoom(pinchBase * scale)
                    }
                    .onEnded { _ in pinchBase = 0; onZoomCommit() }
            )
            .task(id: vault.id) {
                let (g, l) = await Task.detached(priority: .userInitiated) {
                    let g = BrainGraphBuilder.build(notes: BrainVaultStore.notes(in: vault)).graph
                    return (g, MiniGraphLayout.compute(g))
                }.value
                graph = g
                layout = l
            }
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z, BrainBoardLayout.zoomRange.lowerBound), BrainBoardLayout.zoomRange.upperBound)
    }

    private func applyZoom(_ factor: CGFloat) {
        let new = clampZoom(zoom * factor)
        guard new != zoom else { return }
        zoom = new
        onZoomCommit()
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard !layout.points.isEmpty else { return }
        let cx = size.width / 2, cy = size.height / 2
        func project(_ p: CGPoint) -> CGPoint {
            CGPoint(x: cx + (p.x * size.width  - cx) * zoom,
                    y: cy + (p.y * size.height - cy) * zoom)
        }
        var pointFor: [UUID: CGPoint] = [:]
        for (id, np) in layout.points { pointFor[id] = project(np) }

        // Adaptive colors — must read on white AND black (the bug fix: was Color(white:)).
        let edgeColor = Palette.foreground.opacity(0.22)
        let nodeColor = Palette.foreground.opacity(0.72)
        let haloColor = Palette.foreground.opacity(0.06)
        // Thicker edges for small graphs so a 2–3 node brain reads as a graph, not specks.
        let edgeWidth: CGFloat = graph.nodes.count <= 6 ? 1.5 : 0.9

        for e in graph.edges {
            guard let t = e.targetId, let a = pointFor[e.sourceId], let b = pointFor[t] else { continue }
            var path = Path(); path.move(to: a); path.addLine(to: b)
            ctx.stroke(path, with: .color(edgeColor), lineWidth: edgeWidth)
        }
        for node in graph.nodes {
            guard let c = pointFor[node.id] else { continue }
            let r = layout.radii[node.id] ?? 3
            // Faint halo for depth, then the solid node.
            let halo = r + 2.4
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - halo, y: c.y - halo, width: halo * 2, height: halo * 2)), with: .color(haloColor))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(nodeColor))
        }
    }
}

private enum MiniGraphLayout {
    struct Result { var points: [UUID: CGPoint]; var radii: [UUID: CGFloat] }
    static let empty = Result(points: [:], radii: [:])

    static func compute(_ graph: BlockGraph) -> Result {
        let nodes = Array(graph.nodes.prefix(120))
        let n = nodes.count
        guard n > 0 else { return empty }
        let ids = nodes.map(\.id)
        let idSet = Set(ids)
        var pos: [UUID: CGPoint] = [:]
        var vel: [UUID: CGVector] = [:]
        let golden = Double.pi * (3 - 5.0.squareRoot())
        for (i, node) in nodes.enumerated() {
            let radius = (Double(i) / Double(max(n, 1))).squareRoot() * 130
            let theta = Double(i) * golden
            pos[node.id] = CGPoint(x: CGFloat(cos(theta)) * CGFloat(radius), y: CGFloat(sin(theta)) * CGFloat(radius))
            vel[node.id] = .zero
        }
        let edges: [(UUID, UUID)] = graph.edges.compactMap { e in
            guard let t = e.targetId, idSet.contains(e.sourceId), idSet.contains(t) else { return nil }
            return (e.sourceId, t)
        }
        let repulsion: CGFloat = 9000, springLen: CGFloat = 58, springK: CGFloat = 0.02, center: CGFloat = 0.004, damping: CGFloat = 0.85
        let iterations = n <= 2 ? 80 : 280
        for _ in 0..<iterations {
            var force: [UUID: CGVector] = [:]
            for id in ids { force[id] = .zero }
            for i in 0..<n {
                guard let pa = pos[ids[i]] else { continue }
                for j in (i + 1)..<n {
                    guard let pb = pos[ids[j]] else { continue }
                    let dx = pa.x - pb.x, dy = pa.y - pb.y
                    let d2 = max(dx * dx + dy * dy, 0.01), d = sqrt(d2)
                    let f = repulsion / d2, fx = dx / d * f, fy = dy / d * f
                    force[ids[i]]?.dx += fx; force[ids[i]]?.dy += fy
                    force[ids[j]]?.dx -= fx; force[ids[j]]?.dy -= fy
                }
            }
            for (s, t) in edges {
                guard let ps = pos[s], let pt = pos[t] else { continue }
                let dx = pt.x - ps.x, dy = pt.y - ps.y
                let d = max(sqrt(dx * dx + dy * dy), 0.01), disp = d - springLen
                let fx = dx / d * disp * springK, fy = dy / d * disp * springK
                force[s]?.dx += fx; force[s]?.dy += fy
                force[t]?.dx -= fx; force[t]?.dy -= fy
            }
            for id in ids {
                guard let p = pos[id] else { continue }
                force[id]?.dx -= p.x * center; force[id]?.dy -= p.y * center
            }
            for id in ids {
                guard var v = vel[id], var p = pos[id], let f = force[id] else { continue }
                v.dx = (v.dx + f.dx) * damping; v.dy = (v.dy + f.dy) * damping
                p.x += v.dx; p.y += v.dy
                vel[id] = v; pos[id] = p
            }
        }
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = maxX
        for id in ids {
            guard let p = pos[id] else { continue }
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let scale = max(maxX - minX, maxY - minY, n <= 4 ? 40 : 1)   // floor span so 2-node graphs spread, not stack at center
        var degree: [UUID: Int] = [:]
        for (s, t) in edges { degree[s, default: 0] += 1; degree[t, default: 0] += 1 }
        // Small brains (a couple of notes) need bigger nodes + a tighter, more centered
        // spread so they read as a graph rather than two stray dots near the corners.
        let fill: CGFloat = n <= 4 ? 0.42 : 0.80
        let base: CGFloat = n <= 4 ? 7.5 : 2.8
        var points: [UUID: CGPoint] = [:], radii: [UUID: CGFloat] = [:]
        for id in ids {
            guard let p = pos[id] else { continue }
            points[id] = CGPoint(x: (p.x - cx) / scale * fill + 0.5, y: (p.y - cy) / scale * fill + 0.5)
            radii[id] = base + sqrt(CGFloat(degree[id] ?? 0)) * 1.9
        }
        return Result(points: points, radii: radii)
    }
}

// MARK: - Detail (custom back button + in-view actions; no .toolbar)

private struct BrainDetailView: View {
    let vault: BrainVault
    let onBack: () -> Void

    @State private var showImporter = false
    @State private var showInlineURL = false
    @State private var inlineURL = ""
    @State private var status: IngestStatus = .idle
    @State private var banner: String?

    enum IngestStatus: Equatable { case idle, ingesting }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            sourcesView
        }
        .background(Palette.background)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: BrainSourceKind.importerTypes, allowsMultipleSelection: true) { handleAttach($0) }
        .overlay(alignment: .bottom) { bannerView }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)); Text("Brains").font(.system(size: 13)) }
                    .foregroundStyle(Palette.tertiaryForeground)
            }.buttonStyle(.plain)
            Rectangle().fill(Palette.border).frame(width: 1, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(vault.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                if !vault.gist.isEmpty { Text(vault.gist).font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground).lineLimit(1) }
            }
            Spacer()
            if status == .ingesting {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Building…").font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground) }
            }
            IconButton(system: "folder", help: "Open vault in Finder / Obsidian") { NSWorkspace.shared.open(vault.folder) }
            Button { showImporter = true } label: { Label("Add source", systemImage: "plus") }.buttonStyle(PillButtonStyle()).disabled(status == .ingesting)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: Sources (left: source files · right: a grid of "add" tiles)

    private var sourcesView: some View {
        HStack(spacing: 0) {
            sourcesList.frame(width: 300)
            Rectangle().fill(Palette.border).frame(width: 1)
            addGrid.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sourceFiles: [URL] {
        BrainVaultStore.sourceFiles(in: vault.folder)
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var sourcesList: some View {
        let files = sourceFiles
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Sources").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text("\(files.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.tertiaryForeground)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.foreground.opacity(0.06)))
                Spacer()
                if !files.isEmpty {
                    RebuildButton(spinning: status == .ingesting) { Task { await ingest() } }
                        .disabled(status == .ingesting)
                }
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            Rectangle().fill(Palette.border).frame(height: 1)
            if files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 26, weight: .thin)).foregroundStyle(Palette.tertiaryForeground.opacity(0.45))
                    Text("No sources yet").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.foreground)
                    Text("Add files or a link from the right.").font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(files, id: \.self) { SourceFileRow(url: $0) }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(nsColor: Palette.agentSurface))
    }

    private var addGrid: some View {
        VStack(spacing: 0) {
            inlineURLBar
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ADD A SOURCE")
                        .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(Palette.tertiaryForeground)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 160), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(Array(BrainSourceKind.allAddable.enumerated()), id: \.offset) { _, kind in
                            AddTile(kind: kind) {
                                if kind == .web { inlineURL = ""; withAnimation(.easeOut(duration: 0.15)) { showInlineURL = true } }
                                else { showImporter = true }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.background)
    }

    @ViewBuilder private var inlineURLBar: some View {
        if showInlineURL {
            let trimmed = inlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(BrainSourceKind.geoBlue.opacity(0.14))
                    Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(BrainSourceKind.geoBlue)
                }.frame(width: 30, height: 30)
                TextField("https://…  or a YouTube link", text: $inlineURL)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Palette.foreground)
                    .onSubmit { if valid { addInlineURL(trimmed) } }
                Button("Add") { addInlineURL(trimmed) }.buttonStyle(PillButtonStyle()).disabled(!valid)
                Button { withAnimation(.easeOut(duration: 0.15)) { showInlineURL = false } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.tertiaryForeground)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Palette.foreground.opacity(0.06)))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: Palette.agentCardElevated)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BrainSourceKind.geoBlue.opacity(valid ? 0.4 : 0.18), lineWidth: 1))
            .padding(.horizontal, 20).padding(.top, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func addInlineURL(_ link: String) {
        withAnimation(.easeOut(duration: 0.15)) { showInlineURL = false }
        Task { await ingest(sources: [link]) }
    }

    @ViewBuilder private var bannerView: some View {
        if let banner {
            Text(banner).font(.system(size: 11)).foregroundStyle(Palette.background)
                .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(Palette.foreground)).padding(.bottom, 18).transition(.opacity)
        }
    }

    private func handleAttach(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let sources = vault.folder.appendingPathComponent("sources")
        try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dest = sources.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)   // re-adding the same name replaces, not silently fails
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        Task { await ingest() }
    }

    private func ingest(sources: [String] = []) async {
        status = .ingesting
        do {
            let written = try await VaultIngest.ingest(folder: vault.folder, sources: sources)
            showBanner(written > 0 ? "Built \(written) note\(written == 1 ? "" : "s") via Claude Code" : "No new notes (already up to date)")
        } catch {
            showBanner(error.localizedDescription)
        }
        status = .idle
    }

    private func showBanner(_ message: String) {
        withAnimation { banner = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { withAnimation { if banner == message { banner = nil } } }
    }
}

private struct SourceFileRow: View {
    let url: URL
    @State private var hover = false
    private var kind: BrainSourceKind { BrainSourceKind.of(url.pathExtension) }

    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            HStack(spacing: 10) {
                SourceBadge(kind: kind, size: 30, corner: 8, glyph: 13)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.foreground)
                        .lineLimit(1).truncationMode(.middle)
                    Text(kind.displayName.uppercased())
                        .font(.system(size: 9, weight: .medium)).tracking(0.4)
                        .foregroundStyle(Palette.tertiaryForeground)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground)
                    .opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Palette.foreground.opacity(0.05) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(hover ? Palette.border : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain).help("Reveal in Finder").onHover { hover = $0 }
    }
}

private struct AddTile: View {
    let kind: BrainSourceKind
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 11) {
                SourceBadge(kind: kind, size: 46, corner: 12, glyph: 21)
                    .scaleEffect(hover ? 1.06 : 1)
                Text(kind.displayName)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.foreground)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity).frame(height: 112)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: hover ? Palette.agentCardElevated : Palette.agentCard)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover ? kind.tint.opacity(0.45) : Palette.foreground.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(hover ? 0.10 : 0.04), radius: hover ? 8 : 3, y: hover ? 3 : 1)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.background)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Palette.foreground))
                    .padding(7).opacity(hover ? 1 : 0).scaleEffect(hover ? 1 : 0.6)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.03 : 1)
        .animation(.easeOut(duration: 0.14), value: hover)
        .onHover { hover = $0 }
    }
}

// MARK: - Create

private struct CreateBrainSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: BrainVaultStore
    let onCreated: (String) -> Void
    @State private var name = ""
    @State private var gist = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Brain").font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.foreground)
            field("Name", text: $name, placeholder: "Immunology")
            field("Description", text: $gist, placeholder: "What this vault is about")
            if let errorText { Text(errorText).font(.system(size: 11)).foregroundStyle(Color(nsColor: Palette.agentDanger)) }
            HStack {
                Text("~/Geo/Brains/\(BrainVaultStore.slug(name.isEmpty ? "name" : name))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.tertiaryForeground)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(Palette.tertiaryForeground)
                Button("Create") { create() }.buttonStyle(PillButtonStyle()).disabled(trimmed.isEmpty)
            }
        }
        .padding(24).frame(width: 420).background(Palette.background)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.tertiaryForeground)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Palette.foreground)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Palette.agentCard)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border, lineWidth: 1))
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        do {
            let vault = try store.create(name: trimmed, gist: gist.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
            onCreated(vault.id)
        } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Source kinds (NotebookLM-style: pdf/doc/slides/ebook/web/image/audio/data/code/text)

enum BrainSourceKind {
    case pdf, document, presentation, ebook, web, image, audio, data, code, text

    static let geoBlue = Color(red: 0, green: 85.0 / 255.0, blue: 1.0)

    static func of(_ ext: String) -> BrainSourceKind {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "docx", "doc", "rtf", "rtfd", "odt", "pages", "webarchive": return .document
        case "pptx", "key": return .presentation
        case "epub": return .ebook
        case "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp": return .image
        case "mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "caf": return .audio
        case "csv", "tsv", "json", "xml", "numbers": return .data
        case "py", "js", "ts", "tsx", "jsx", "swift", "go", "rs", "rb", "java", "c", "h", "cpp", "sh", "yaml", "yml", "sql": return .code
        case "html", "htm", "url": return .web
        default: return .text
        }
    }

    var icon: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .presentation: return "rectangle.on.rectangle.angled"
        case .ebook: return "book"
        case .web: return "globe"
        case .image: return "photo"
        case .audio: return "waveform"
        case .data: return "tablecells"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.plaintext"
        }
    }

    var tint: Color {
        switch self {
        case .pdf, .ebook: return Color(nsColor: Palette.agentDanger)
        case .image, .audio, .presentation: return Color(nsColor: Palette.agentWarning)
        case .data, .code: return Color(nsColor: Palette.agentSuccess)
        case .web: return Self.geoBlue
        case .document, .text: return Palette.foreground   // a real neutral (not muted-gray "disabled" look)
        }
    }

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .document: return "Document"
        case .presentation: return "Slides"
        case .ebook: return "E-book"
        case .web: return "Web"
        case .image: return "Image"
        case .audio: return "Audio"
        case .data: return "Data"
        case .code: return "Code"
        case .text: return "Text"
        }
    }

    static let allAddable: [BrainSourceKind] = [.pdf, .document, .presentation, .ebook, .web, .image, .audio, .data, .code, .text]

    // Broad on purpose: the grid advertises every kind, so the importer must be able
    // to select any of them; brain.py decides per-source what it can actually distill.
    static let importerTypes: [UTType] = [.data]
}

// MARK: - Graph mapping (notes + [[wikilinks]] → BlockGraph; reuses the app's GraphView)

private enum BrainGraphBuilder {
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]|]+)(?:\|[^\[\]]+)?\]\]"#)

    static func build(notes: [BrainNote]) -> (graph: BlockGraph, lookup: [UUID: BrainNote]) {
        var idForSlug: [String: UUID] = [:]
        var lookup: [UUID: BrainNote] = [:]
        var order: [(note: BrainNote, id: UUID)] = []
        order.reserveCapacity(notes.count)
        for note in notes {
            let id = stableID(for: note.id)
            idForSlug[note.id.lowercased()] = id
            lookup[id] = note
            order.append((note, id))
        }

        var edges: [GraphEdge] = []
        var seen = Set<EdgeKey>()
        var degree: [UUID: Int] = [:]
        for (note, sourceId) in order {
            let body = note.body as NSString
            for m in linkRegex.matches(in: note.body, range: NSRange(location: 0, length: body.length)) {
                let raw = body.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty { continue }
                let key = raw.lowercased()
                if key == "index" || key == note.id.lowercased() { continue }
                if let targetId = idForSlug[key] {
                    if targetId == sourceId { continue }
                    guard seen.insert(EdgeKey(source: sourceId, target: targetId, title: nil)).inserted else { continue }
                    edges.append(GraphEdge(id: stableID(for: "\(sourceId.uuidString)->\(targetId.uuidString)"), sourceId: sourceId, targetId: targetId, targetTitle: raw))
                    degree[sourceId, default: 0] += 1
                    degree[targetId, default: 0] += 1
                } else {
                    guard seen.insert(EdgeKey(source: sourceId, target: nil, title: key)).inserted else { continue }
                    edges.append(GraphEdge(id: stableID(for: "\(sourceId.uuidString)~>\(key)"), sourceId: sourceId, targetId: nil, targetTitle: raw))
                }
            }
        }

        // Floor the weight so unlinked notes (a brand-new vault) still render as
        // visible nodes with labels instead of 5pt specks that fade out when zoomed.
        let nodes = order.map { entry in
            GraphNode(id: entry.id, title: entry.note.title, tagColor: nil, type: .permanent, layer: .agent, weight: max(1, degree[entry.id] ?? 0))
        }
        return (BlockGraph(nodes: nodes, edges: edges), lookup)
    }

    // Deterministic UUID from the note slug (FNV-1a, two seeds → 128 bits) so a rebuild
    // after ingest keeps existing nodes in place and only animates the new ones in.
    private static func stableID(for slug: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for byte in slug.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
            return h
        }
        let hi = fnv(0xcbf29ce484222325).bigEndian
        let lo = fnv(0x100000001b3).bigEndian
        let b = withUnsafeBytes(of: (hi, lo)) { Array($0) }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private struct EdgeKey: Hashable {
        let source: UUID
        let target: UUID?
        let title: String?
    }
}
