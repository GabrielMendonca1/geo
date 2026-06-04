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
    @State private var showCreate = false
    @State private var openVaultId: String?

    // Big cells so each graph reads as a graph, not a thumbnail — a wall of graphs.
    private let columns = [GridItem(.adaptive(minimum: 340, maximum: 460), spacing: 20)]

    var body: some View {
        Pane {
            Group {
                if let id = openVaultId, let vault = store.vaults.first(where: { $0.id == id }) {
                    BrainDetailView(vault: vault, onBack: { openVaultId = nil; store.reload() })
                } else {
                    listView
                }
            }
        }
        .sheet(isPresented: $showCreate) { CreateBrainSheet(store: store) { openVaultId = $0 } }
        .task { store.reload() }
    }

    private var listView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Brains").font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.foreground)
                    Text("\(store.vaults.count) vault\(store.vaults.count == 1 ? "" : "s") · ~/Geo/Brains")
                        .font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground)
                }
                Spacer()
                IconButton(system: "folder", help: "Reveal ~/Geo/Brains in Finder") { NSWorkspace.shared.open(BrainVaultStore.root) }
                Button { showCreate = true } label: { Label("New Brain", systemImage: "plus") }.buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            Rectangle().fill(Palette.border).frame(height: 1)
            if store.vaults.isEmpty { emptyState } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(store.vaults) { vault in
                            Button { openVaultId = vault.id } label: { BrainGraphCell(vault: vault) }.buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                }
            }
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

// MARK: - Graph cell (an Obsidian-style graph tile; the graph IS the card)

private struct BrainGraphCell: View {
    let vault: BrainVault
    @State private var hover = false

    private let corner: CGFloat = 18

    var body: some View {
        ZStack {
            // The graph fills the cell edge-to-edge (its own internal inset keeps
            // nodes off the corners), so the tile reads as a panel of pure graph.
            if vault.noteCount == 0 {
                EmptyGraphMotif()
            } else {
                BrainMiniGraph(vault: vault)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .background(Color(nsColor: hover ? Palette.agentCardElevated : Palette.agentCard))
        .overlay(alignment: .bottom) { labelOverlay }
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(hover ? Palette.foreground.opacity(0.28) : Palette.foreground.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(hover ? 0.16 : 0), radius: hover ? 14 : 0, y: hover ? 6 : 0)
        .scaleEffect(hover ? 1.01 : 1)
        .animation(.easeOut(duration: 0.14), value: hover)
        .onHover { hover = $0 }
    }

    // Subtle scrim + minimal chrome: name, a state dot, and counts — legible on any graph.
    private var labelOverlay: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(vault.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(vault.ready ? Color(nsColor: Palette.agentSuccess) : Palette.tertiaryForeground).frame(width: 6, height: 6)
                    Text(countLabel).font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.foreground.opacity(hover ? 0.85 : 0.4))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Soft bottom-up scrim so the label stays readable over light OR dark graphs.
            LinearGradient(
                colors: [Palette.background.opacity(0), Palette.background.opacity(0.72), Palette.background.opacity(0.94)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
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

private struct BrainMiniGraph: View {
    let vault: BrainVault
    @State private var graph: BlockGraph = .empty
    @State private var layout = MiniGraphLayout.empty

    var body: some View {
        Canvas { ctx, size in draw(ctx, size) }
            // Fill the cell; layout's own inset (see MiniGraphLayout) keeps nodes off corners.
            .padding(10)
            .task(id: vault.id) {
                let g = BrainGraphBuilder.build(notes: BrainVaultStore.notes(in: vault)).graph
                let l = MiniGraphLayout.compute(g)
                graph = g
                layout = l
            }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard !layout.points.isEmpty else { return }
        // Fill the whole (non-square) cell — graphs should sprawl, not sit in a centered box.
        func project(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
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
        let scale = max(maxX - minX, maxY - minY, 1)
        var degree: [UUID: Int] = [:]
        for (s, t) in edges { degree[s, default: 0] += 1; degree[t, default: 0] += 1 }
        // Small brains (a couple of notes) need bigger nodes + a tighter, more centered
        // spread so they read as a graph rather than two stray dots near the corners.
        let fill: CGFloat = n <= 4 ? 0.58 : 0.80
        let base: CGFloat = n <= 4 ? 6.5 : 2.8
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
                VStack(alignment: .leading, spacing: 22) {
                    addSection(title: "Add a file", kinds: BrainSourceKind.allAddable.filter { $0 != .web })
                    addSection(title: "From the web", kinds: BrainSourceKind.allAddable.filter { $0 == .web })
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.background)
    }

    private func addSection(title: String, kinds: [BrainSourceKind]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Palette.tertiaryForeground)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 160), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                    AddTile(kind: kind) {
                        if kind == .web { inlineURL = ""; withAnimation(.easeOut(duration: 0.15)) { showInlineURL = true } }
                        else { showImporter = true }
                    }
                }
            }
        }
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
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover ? kind.tint.opacity(0.45) : Palette.border, lineWidth: 1))
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
