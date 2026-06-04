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

    static func meta(in folder: URL) -> BrainMeta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".brain.json")) else { return nil }
        return try? JSONDecoder().decode(BrainMeta.self, from: data)
    }

    static func noteFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "index.md" }
    }

    static func sourceFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("sources"), includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
    }

    static func notes(in vault: BrainVault) -> [BrainNote] {
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

    static func slug(_ s: String) -> String {
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

// MARK: - In-app ingest (writes .md notes into the ~/Geo/Brains vault; same files the CLI/agent use)

enum VaultIngest {
    @discardableResult
    static func ingest(folder: URL, title: String, summarizer: ChunkSummarizer = AnthropicHaikuSummarizer()) async throws -> Int {
        let sources = BrainVaultStore.sourceFiles(in: folder)
        let existingHashes = Set(BrainVaultStore.noteFiles(in: folder).compactMap { frontmatterValue("chunk", in: $0) })
        var usedSlugs = Set(BrainVaultStore.noteFiles(in: folder).map { $0.deletingPathExtension().lastPathComponent })
        var written = 0
        for src in sources where SourceExtractor.supportedExtensions.contains(src.pathExtension.lowercased()) {
            let text = try SourceExtractor.extractText(from: src)
            for chunk in Chunker.chunk(text, sourceLabel: src.lastPathComponent) where !existingHashes.contains(chunk.hash) {
                let md = try await summarizer.summarize(chunk.text, context: SummarizeContext(brainTitle: title, brainGist: "", sourceLabel: src.lastPathComponent))
                let noteTitle = titleOf(md, fallback: src.deletingPathExtension().lastPathComponent)
                var slug = BrainVaultStore.slug(noteTitle); let base = slug; var n = 1
                while usedSlugs.contains(slug) || slug.isEmpty { slug = "\(base.isEmpty ? "note" : base)-\(n)"; n += 1 }
                usedSlugs.insert(slug)
                let front = "---\ntype: literature\nsource: \(src.lastPathComponent)\nchunk: \(chunk.hash)\ncreated: \(ISO8601DateFormatter().string(from: Date()))\n---\n"
                try (front + md.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: folder.appendingPathComponent("\(slug).md"), atomically: true, encoding: .utf8)
                written += 1
            }
        }
        let meta = BrainVaultStore.meta(in: folder)
        rebuildIndex(in: folder, title: meta?.title ?? title, gist: meta?.gist ?? "")
        return written
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

    private static func frontmatterValue(_ key: String, in url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("\(key):") { return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) }
            if line.trimmingCharacters(in: .whitespaces) == "---", line != raw.components(separatedBy: "\n").first { break }
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
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(store.vaults) { vault in
                            Button { openVaultId = vault.id } label: { BrainCard(vault: vault) }.buttonStyle(.plain)
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
            HStack(spacing: 10) {
                Label("\(vault.noteCount)", systemImage: "doc.text")
                Label("\(vault.sourceCount)", systemImage: "paperclip")
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

private struct BrainDetailView: View {
    let vault: BrainVault
    let onBack: () -> Void

    @State private var notes: [BrainNote] = []
    @State private var selected: BrainNote?
    @State private var showImporter = false
    @State private var status: IngestStatus = .idle
    @State private var banner: String?

    enum IngestStatus: Equatable { case idle, ingesting }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(spacing: 0) {
                sidebar.frame(width: 280)
                Rectangle().fill(Palette.border).frame(width: 1)
                reader.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .plainText, .text, .html], allowsMultipleSelection: true) { handleAttach($0) }
        .overlay(alignment: .bottom) { bannerView }
        .task { reload() }
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
            Button { showImporter = true } label: { Label("Attach", systemImage: "paperclip") }.buttonStyle(PillButtonStyle()).disabled(status == .ingesting)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(notes.count) note\(notes.count == 1 ? "" : "s")").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.tertiaryForeground)
                Spacer()
                if !BrainVaultStore.sourceFiles(in: vault.folder).isEmpty {
                    Button("Rebuild") { Task { await ingest() } }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.tertiaryForeground).disabled(status == .ingesting)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView { LazyVStack(spacing: 2) { ForEach(notes) { note in NoteRow(note: note, isSelected: selected?.id == note.id) { selected = note } } }.padding(8) }
        }
        .background(Color(nsColor: Palette.agentSurface))
    }

    @ViewBuilder private var reader: some View {
        if let selected { NoteReader(note: selected) }
        else if notes.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray").font(.system(size: 34, weight: .thin)).foregroundStyle(Palette.tertiaryForeground.opacity(0.5))
                Text("Empty vault").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text("Attach a PDF / .md / .txt and it'll be distilled into linked notes.").font(.system(size: 12)).foregroundStyle(Palette.tertiaryForeground).multilineTextAlignment(.center)
                Button { showImporter = true } label: { Label("Attach sources", systemImage: "paperclip") }.buttonStyle(PillButtonStyle()).padding(.top, 4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a note").font(.system(size: 13)).foregroundStyle(Palette.tertiaryForeground).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var bannerView: some View {
        if let banner {
            Text(banner).font(.system(size: 11)).foregroundStyle(Palette.background)
                .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(Palette.foreground)).padding(.bottom, 18).transition(.opacity)
        }
    }

    private func reload() {
        notes = BrainVaultStore.notes(in: vault)
        if selected == nil || !notes.contains(where: { $0.id == selected?.id }) { selected = notes.first }
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

    private func ingest() async {
        status = .ingesting
        do {
            let written = try await VaultIngest.ingest(folder: vault.folder, title: vault.title)
            reload()
            showBanner(written > 0 ? "Built \(written) note\(written == 1 ? "" : "s")" : "No new notes (already up to date)")
        } catch let error as AnthropicClientError {
            showBanner(error.localizedDescription)
        } catch {
            showBanner("Ingest failed: \(error.localizedDescription)")
        }
        status = .idle
    }

    private func showBanner(_ message: String) {
        withAnimation { banner = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { withAnimation { if banner == message { banner = nil } } }
    }
}

private struct NoteRow: View {
    let note: BrainNote
    let isSelected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground)
                Text(note.title).font(.system(size: 12.5)).foregroundStyle(Palette.foreground).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Palette.foreground.opacity(0.10) : (hover ? Palette.foreground.opacity(0.04) : .clear)))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
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
