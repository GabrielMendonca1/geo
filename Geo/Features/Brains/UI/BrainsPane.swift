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

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 440), spacing: 16)]

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
        .sheet(isPresented: $showCreate) { CreateBrainSheet(store: store) { BrainGraphBuilder.sanitizeSharedGraphSettings(); openVaultId = $0 } }
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
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(store.vaults) { vault in
                            Button { BrainGraphBuilder.sanitizeSharedGraphSettings(); openVaultId = vault.id } label: { BrainCard(vault: vault) }.buttonStyle(.plain)
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

private struct StateBadge: View {
    let ready: Bool
    var body: some View {
        let color = ready ? Color(nsColor: Palette.agentSuccess) : Palette.tertiaryForeground
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(ready ? "ready" : "empty").font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct BrainCard: View {
    let vault: BrainVault
    @State private var hover = false

    private var sourceKinds: [BrainSourceKind] {
        var seen = Set<String>()
        var out: [BrainSourceKind] = []
        for file in BrainVaultStore.sourceFiles(in: vault.folder) {
            let ext = file.pathExtension.lowercased()
            if seen.insert(ext).inserted { out.append(BrainSourceKind.of(ext)) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ZStack { Circle().fill(Palette.foreground.opacity(0.06)); Image(systemName: "brain.head.profile").font(.system(size: 15)).foregroundStyle(Palette.foreground.opacity(0.85)) }.frame(width: 34, height: 34)
                Spacer()
                StateBadge(ready: vault.ready)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(vault.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground).lineLimit(1)
                Text(vault.gist.isEmpty ? "No description" : vault.gist).font(.system(size: 12)).foregroundStyle(Palette.tertiaryForeground).lineLimit(2).frame(height: 32, alignment: .top)
            }
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Label("\(vault.noteCount)", systemImage: "doc.text")
                if !sourceKinds.isEmpty {
                    Text("·").foregroundStyle(Palette.tertiaryForeground.opacity(0.5))
                    ForEach(Array(sourceKinds.prefix(4).enumerated()), id: \.offset) { _, kind in
                        Image(systemName: kind.icon).foregroundStyle(kind.tint.opacity(0.85))
                    }
                    if sourceKinds.count > 4 { Text("+\(sourceKinds.count - 4)") }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.tertiaryForeground.opacity(hover ? 0.9 : 0.4))
            }.font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground)
        }
        .padding(16).frame(height: 152, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: hover ? Palette.agentCardElevated : Palette.agentCard)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hover ? Palette.foreground.opacity(0.22) : Palette.border, lineWidth: 1))
        .scaleEffect(hover ? 1.012 : 1).animation(.easeOut(duration: 0.13), value: hover).onHover { hover = $0 }
    }
}

// MARK: - Detail (custom back button + in-view actions; no .toolbar)

private enum DetailMode: String, CaseIterable { case graph = "Graph", sources = "Sources" }

private struct BrainDetailView: View {
    let vault: BrainVault
    let onBack: () -> Void

    @State private var mode: DetailMode = .graph
    @State private var notes: [BrainNote] = []
    @State private var brainGraph: (graph: BlockGraph, lookup: [UUID: BrainNote]) = (.empty, [:])
    @State private var selectedNote: BrainNote?
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
            content
        }
        .background(Palette.background)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: BrainSourceKind.importerTypes, allowsMultipleSelection: true) { handleAttach($0) }
        .overlay(alignment: .bottom) { bannerView }
        .task { reload() }
    }

    private func openSources() { withAnimation(.easeOut(duration: 0.15)) { mode = .sources } }

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
            Picker("", selection: $mode) {
                ForEach(DetailMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            if status == .ingesting {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Building…").font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground) }
            }
            IconButton(system: "folder", help: "Open vault in Finder / Obsidian") { NSWorkspace.shared.open(vault.folder) }
            Button { openSources() } label: { Label("Add source", systemImage: "plus") }.buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        if mode == .sources {
            sourcesView
        } else if notes.isEmpty {
            emptyVaultState
        } else {
            graphLayer
        }
    }

    // MARK: Graph mode (reuses the app's GraphView wholesale)

    private var graphLayer: some View {
        ZStack(alignment: .trailing) {
            GraphView(
                graph: brainGraph.graph,
                isActive: { mode == .graph && selectedNote == nil },
                onNodeTap: { id in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        selectedNote = brainGraph.lookup[id]
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let note = selectedNote {
                inspector(note)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
            }
        }
    }

    private func inspector(_ note: BrainNote) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Palette.border).frame(width: 1)
            VStack(spacing: 0) {
                HStack {
                    Text(note.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground).lineLimit(1)
                    Spacer()
                    IconButton(system: "xmark", help: "Close") {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { selectedNote = nil }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(Palette.border).frame(height: 1)
                NoteReader(note: note)
            }
            .frame(width: 420)
            .background(Color(nsColor: Palette.agentSurface))
        }
    }

    private var emptyVaultState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 34, weight: .thin)).foregroundStyle(Palette.tertiaryForeground.opacity(0.5))
            Text("Empty vault").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
            Text("Add a PDF, doc, slide deck, e-book, image, audio file, or a web URL —\nit'll be distilled into linked notes.").font(.system(size: 12)).foregroundStyle(Palette.tertiaryForeground).multilineTextAlignment(.center)
            Button { showAddSource = true } label: { Label("Add a source", systemImage: "plus") }.buttonStyle(PillButtonStyle()).padding(.top, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sources mode (left: source files · right: a grid of "add" tiles)

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
            HStack {
                Text("\(files.count) source\(files.count == 1 ? "" : "s")").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.tertiaryForeground)
                Spacer()
                if !files.isEmpty {
                    Button("Rebuild") { Task { await ingest() } }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.tertiaryForeground).disabled(status == .ingesting)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Rectangle().fill(Palette.border).frame(height: 1)
            if files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 22, weight: .thin)).foregroundStyle(Palette.tertiaryForeground.opacity(0.5))
                    Text("No sources yet").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.foreground)
                    Text("Add one from the grid →").font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 2) { ForEach(files, id: \.self) { SourceFileRow(url: $0) } }.padding(8) }
            }
        }
        .background(Color(nsColor: Palette.agentSurface))
    }

    private var addGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(Array(BrainSourceKind.allAddable.enumerated()), id: \.offset) { _, kind in
                    AddTile(kind: kind) {
                        if kind == .web { inlineURL = ""; withAnimation(.easeOut(duration: 0.15)) { showInlineURL = true } }
                        else { showImporter = true }
                    }
                }
            }
            .padding(20)
        }
        .background(Palette.background)
        .overlay(alignment: .top) { inlineURLBar }
    }

    @ViewBuilder private var inlineURLBar: some View {
        if showInlineURL {
            let trimmed = inlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(BrainSourceKind.geoBlue)
                TextField("https://…  or a YouTube link", text: $inlineURL)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Palette.foreground)
                    .onSubmit { if valid { addInlineURL(trimmed) } }
                Button("Add") { addInlineURL(trimmed) }.buttonStyle(PillButtonStyle()).disabled(!valid)
                Button { withAnimation(.easeOut(duration: 0.15)) { showInlineURL = false } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.tertiaryForeground)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Palette.agentCardElevated)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border, lineWidth: 1))
            .padding(16)
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

    private func reload() {
        notes = BrainVaultStore.notes(in: vault)
        brainGraph = BrainGraphBuilder.build(notes: notes)
        if let sel = selectedNote, !notes.contains(where: { $0.id == sel.id }) { selectedNote = nil }
    }

    private func handleAttach(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let sources = vault.folder.appendingPathComponent("sources")
        try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try? FileManager.default.copyItem(at: url, to: sources.appendingPathComponent(url.lastPathComponent))
        }
        Task { await ingest() }
    }

    private func ingest(sources: [String] = []) async {
        status = .ingesting
        do {
            let written = try await VaultIngest.ingest(folder: vault.folder, sources: sources)
            reload()
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
            HStack(spacing: 8) {
                Image(systemName: kind.icon).font(.system(size: 12)).foregroundStyle(kind.tint.opacity(0.9)).frame(width: 16)
                Text(url.lastPathComponent).font(.system(size: 12.5)).foregroundStyle(Palette.foreground).lineLimit(1)
                Spacer(minLength: 0)
                if hover { Image(systemName: "arrow.up.forward.app").font(.system(size: 10)).foregroundStyle(Palette.tertiaryForeground) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Palette.foreground.opacity(0.04) : .clear))
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
            VStack(spacing: 10) {
                Image(systemName: kind.icon).font(.system(size: 24, weight: .regular)).foregroundStyle(kind.tint.opacity(hover ? 1 : 0.9))
                Text(kind.displayName).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.foreground).lineLimit(1)
            }
            .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: hover ? Palette.agentCardElevated : Palette.agentCard)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover ? Palette.foreground.opacity(0.22) : Palette.border, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.tertiaryForeground.opacity(hover ? 0.9 : 0.35)).padding(8)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.02 : 1).animation(.easeOut(duration: 0.13), value: hover).onHover { hover = $0 }
    }
}

// MARK: - Reader (lightweight Markdown, [[wikilinks]] highlighted)

private struct NoteReader: View {
    let note: BrainNote
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in MarkdownLine(line).view }
                Label("Read-only · \(note.url.lastPathComponent)", systemImage: "lock").font(.system(size: 10)).foregroundStyle(Palette.tertiaryForeground).padding(.top, 16)
            }
            .frame(maxWidth: 720, alignment: .leading).padding(.horizontal, 44).padding(.vertical, 36).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.background)
    }
    private var lines: [String] { note.body.components(separatedBy: "\n") }
}

private struct MarkdownLine {
    let raw: String
    init(_ raw: String) { self.raw = raw }

    @ViewBuilder var view: some View {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("# ") { inline(String(t.dropFirst(2))).font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.foreground) }
        else if t.hasPrefix("## ") { inline(String(t.dropFirst(3))).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.foreground).padding(.top, 6) }
        else if t.hasPrefix("### ") { inline(String(t.dropFirst(4))).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground) }
        else if t.hasPrefix("- ") || t.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 8) { Circle().fill(Palette.tertiaryForeground).frame(width: 4, height: 4).padding(.top, 8); inline(String(t.dropFirst(2))).font(.system(size: 14)).foregroundStyle(Palette.foreground.opacity(0.92)) }
        }
        else if t.isEmpty { Spacer().frame(height: 2) }
        else { inline(t).font(.system(size: 14)).foregroundStyle(Palette.foreground.opacity(0.92)).lineSpacing(4) }
    }

    private func inline(_ s: String) -> Text {
        guard let re = try? NSRegularExpression(pattern: #"\[\[([^\[\]|]+)(?:\|([^\[\]]+))?\]\]"#) else { return Text(s) }
        let ns = s as NSString
        var result = Text("")
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { result = result + Text(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            let labelRange = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 1)
            result = result + Text(ns.substring(with: labelRange)).foregroundColor(Palette.foreground).underline().fontWeight(.medium)
            last = m.range.location + m.range.length
        }
        if last < ns.length { result = result + Text(ns.substring(from: last)) }
        return result
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
        case .document, .text: return Palette.tertiaryForeground
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

    static let importerTypes: [UTType] = {
        var types: [UTType] = [.pdf, .plainText, .text, .html, .rtf, .epub, .image, .audio, .json, .commaSeparatedText]
        types += ["org.openxmlformats.wordprocessingml.document",
                  "org.openxmlformats.presentationml.presentation",
                  "com.microsoft.word.doc"].compactMap { UTType($0) }
        return types
    }()
}

private struct SupportedTypesStrip: View {
    private let kinds: [BrainSourceKind] = [.pdf, .document, .presentation, .ebook, .web, .image, .audio, .data, .code, .text]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                Image(systemName: kind.icon).font(.system(size: 11))
                    .foregroundStyle(kind.tint.opacity(0.85))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Palette.agentCard)))
            }
        }
    }
}

private struct AddSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onChooseFiles: () -> Void
    let onAddURL: (String) -> Void
    @State private var url = ""

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isLikelyURL: Bool { trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://") }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a source").font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.foreground)

            VStack(alignment: .leading, spacing: 6) {
                Label("From the web", systemImage: "globe").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.tertiaryForeground)
                HStack(spacing: 8) {
                    TextField("https://…  or a YouTube link", text: $url)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Palette.foreground)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Palette.agentCard)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border, lineWidth: 1))
                        .onSubmit { if isLikelyURL { onAddURL(trimmedURL) } }
                    Button("Add") { onAddURL(trimmedURL) }.buttonStyle(PillButtonStyle()).disabled(!isLikelyURL)
                }
            }

            HStack(spacing: 8) {
                Rectangle().fill(Palette.border).frame(height: 1)
                Text("or").font(.system(size: 10)).foregroundStyle(Palette.tertiaryForeground)
                Rectangle().fill(Palette.border).frame(height: 1)
            }

            Button(action: onChooseFiles) {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 20)).foregroundStyle(Palette.tertiaryForeground)
                    Text("Choose files…").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.foreground)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Palette.agentCard)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(Palette.border))
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text("Supported").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.tertiaryForeground)
                SupportedTypesStrip()
            }

            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(Palette.tertiaryForeground) }
        }
        .padding(24).frame(width: 460).background(Palette.background)
    }
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
                    edges.append(GraphEdge(id: UUID(), sourceId: sourceId, targetId: targetId, targetTitle: raw))
                    degree[sourceId, default: 0] += 1
                    degree[targetId, default: 0] += 1
                } else {
                    guard seen.insert(EdgeKey(source: sourceId, target: nil, title: key)).inserted else { continue }
                    edges.append(GraphEdge(id: UUID(), sourceId: sourceId, targetId: nil, targetTitle: raw))
                }
            }
        }

        let nodes = order.map { entry in
            GraphNode(id: entry.id, title: entry.note.title, tagColor: nil, type: .permanent, layer: .agent, weight: degree[entry.id] ?? 0)
        }
        return (BlockGraph(nodes: nodes, edges: edges), lookup)
    }

    // GraphView persists settings under a single global key shared with the main graph.
    // A leftover search term / hidden group there would silently blank the brain graph
    // (which has no in-pane search box) — clear only those brain-hostile filters on open.
    static func sanitizeSharedGraphSettings() {
        let key = "geo.graphSettings.v2"
        guard var s = UserDefaults.standard.data(forKey: key).flatMap({ try? JSONDecoder().decode(GraphSettings.self, from: $0) }) else { return }
        guard !s.searchText.isEmpty || !s.hiddenGroups.isEmpty || !s.showOrphans else { return }
        s.searchText = ""; s.hiddenGroups = []; s.showOrphans = true
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
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
