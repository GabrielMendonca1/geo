import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - File-native model (~/Geo/Brains/<name>/ vaults are the source of truth)

private struct BrainMeta: Codable {
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
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(".brain.json")),
                  let meta = try? JSONDecoder().decode(BrainMeta.self, from: data) else { continue }
            found.append(BrainVault(
                id: meta.id,
                title: meta.title,
                gist: meta.gist,
                noteCount: Self.noteFiles(in: dir).count,
                sourceCount: meta.sources?.count ?? 0,
                folder: dir
            ))
        }
        vaults = found.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    static func noteFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "index.md" }
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
        let meta = BrainMeta(id: id, title: name, gist: gist, created: iso, updated: iso, nodes: 0, sources: [])
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: dir.appendingPathComponent(".brain.json"))
        var index = "# \(name)\n\n"
        if !gist.isEmpty { index += gist + "\n\n" }
        index += "## Notes (0)\n"
        try index.write(to: dir.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        reload()
        return vaults.first { $0.id == id } ?? BrainVault(id: id, title: name, gist: gist, noteCount: 0, sourceCount: 0, folder: dir)
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let cleaned = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(cleaned).split(separator: "-").joined(separator: "-")
    }
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

// MARK: - Pane

struct BrainsPane: View {
    @StateObject private var store = BrainVaultStore()
    @State private var showCreate = false

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 440), spacing: 16)]

    var body: some View {
        NavigationStack {
            Pane {
                VStack(spacing: 0) {
                    header
                    Rectangle().fill(Palette.border).frame(height: 1)
                    content
                }
            }
            .navigationDestination(for: BrainVault.self) { BrainDetailView(vault: $0) }
        }
        .sheet(isPresented: $showCreate) { CreateBrainSheet(store: store) }
        .task { store.reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Brains").font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.foreground)
                Text("\(store.vaults.count) vault\(store.vaults.count == 1 ? "" : "s") · ~/Geo/Brains")
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground)
            }
            Spacer()
            Button { NSWorkspace.shared.open(BrainVaultStore.root) } label: {
                Image(systemName: "folder").font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundStyle(Palette.tertiaryForeground).help("Reveal ~/Geo/Brains in Finder")
            Button { showCreate = true } label: { Label("New Brain", systemImage: "plus") }
                .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
    }

    @ViewBuilder private var content: some View {
        if store.vaults.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(store.vaults) { vault in
                        NavigationLink(value: vault) { BrainCard(vault: vault) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(24)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(Palette.tertiaryForeground.opacity(0.55))
            Text("No brains yet").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.foreground)
            Text("Create a vault here — or build one from the terminal:")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiaryForeground)
            Text("brain ingest <name> <files…>")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.foreground.opacity(0.7))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Palette.agentCard)))
            Button { showCreate = true } label: { Label("New Brain", systemImage: "plus") }
                .buttonStyle(PillButtonStyle()).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card

private struct BrainCard: View {
    let vault: BrainVault
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ZStack {
                    Circle().fill(Palette.foreground.opacity(0.06))
                    Image(systemName: "brain.head.profile").font(.system(size: 15)).foregroundStyle(Palette.foreground.opacity(0.85))
                }
                .frame(width: 34, height: 34)
                Spacer()
                StateBadge(ready: vault.ready)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(vault.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground).lineLimit(1)
                Text(vault.gist.isEmpty ? "No description" : vault.gist)
                    .font(.system(size: 12)).foregroundStyle(Palette.tertiaryForeground)
                    .lineLimit(2).frame(height: 32, alignment: .top)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Label("\(vault.noteCount)", systemImage: "doc.text")
                Label("\(vault.sourceCount)", systemImage: "paperclip")
                Spacer()
            }
            .font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground)
        }
        .padding(16)
        .frame(height: 152, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: hover ? Palette.agentCardElevated : Palette.agentCard)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hover ? Palette.foreground.opacity(0.22) : Palette.border, lineWidth: 1))
        .scaleEffect(hover ? 1.012 : 1)
        .animation(.easeOut(duration: 0.13), value: hover)
        .onHover { hover = $0 }
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
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Capsule().fill(Palette.foreground.opacity(configuration.isPressed ? 0.82 : 1)))
            .foregroundStyle(Palette.background)
    }
}

// MARK: - Detail

private struct BrainDetailView: View {
    let vault: BrainVault
    @State private var notes: [BrainNote] = []
    @State private var selected: BrainNote?
    @State private var showImporter = false
    @State private var toast: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 280)
            Rectangle().fill(Palette.border).frame(width: 1)
            reader.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.background)
        .navigationTitle(vault.title)
        .toolbar {
            ToolbarItemGroup {
                Button { NSWorkspace.shared.open(vault.folder) } label: { Image(systemName: "folder") }
                    .help("Open vault in Finder / Obsidian")
                Button { showImporter = true } label: { Label("Attach", systemImage: "paperclip") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .plainText, .text, .html], allowsMultipleSelection: true) { handleAttach($0) }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.system(size: 11)).foregroundStyle(Palette.background)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Palette.foreground))
                    .padding(.bottom, 18).transition(.opacity)
            }
        }
        .task { reload() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(vault.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                if !vault.gist.isEmpty {
                    Text(vault.gist).font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground).lineLimit(2)
                }
                Text("\(notes.count) note\(notes.count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(Palette.tertiaryForeground).padding(.top, 2)
            }
            .padding(16)
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(notes) { note in
                        NoteRow(note: note, isSelected: selected?.id == note.id) { selected = note }
                    }
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: Palette.agentSurface))
    }

    @ViewBuilder private var reader: some View {
        if let selected {
            NoteReader(note: selected)
        } else if notes.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray").font(.system(size: 34, weight: .thin)).foregroundStyle(Palette.tertiaryForeground.opacity(0.5))
                Text("Empty vault").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text("Attach sources, then run `brain ingest \(vault.id)`\n(or ask the agent — it can ingest with the app closed)")
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a note").font(.system(size: 13)).foregroundStyle(Palette.tertiaryForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reload() {
        notes = BrainVaultStore.notes(in: vault)
        if selected == nil { selected = notes.first }
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
        showToast("Added \(urls.count) source\(urls.count == 1 ? "" : "s") — run `brain ingest \(vault.id)`")
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { withAnimation { if toast == message { toast = nil } } }
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
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Reader (lightweight Markdown rendering, [[wikilinks]] highlighted)

private struct NoteReader: View {
    let note: BrainNote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    block.view
                }
                Label("Read-only · \(note.url.lastPathComponent)", systemImage: "lock")
                    .font(.system(size: 10)).foregroundStyle(Palette.tertiaryForeground).padding(.top, 16)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 44).padding(.vertical, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.background)
    }

    private var blocks: [MarkdownBlock] {
        note.body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            MarkdownBlock(String(line))
        }
    }
}

private struct MarkdownBlock {
    let raw: String
    init(_ raw: String) { self.raw = raw }

    @ViewBuilder var view: some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") {
            inline(String(trimmed.dropFirst(2))).font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.foreground)
        } else if trimmed.hasPrefix("## ") {
            inline(String(trimmed.dropFirst(3))).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.foreground).padding(.top, 6)
        } else if trimmed.hasPrefix("### ") {
            inline(String(trimmed.dropFirst(4))).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Palette.tertiaryForeground).frame(width: 4, height: 4).padding(.top, 8)
                inline(String(trimmed.dropFirst(2))).font(.system(size: 14)).foregroundStyle(Palette.foreground.opacity(0.92))
            }
        } else if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else {
            inline(trimmed).font(.system(size: 14)).foregroundStyle(Palette.foreground.opacity(0.92)).lineSpacing(4)
        }
    }

    private func inline(_ s: String) -> Text {
        let pattern = try? NSRegularExpression(pattern: #"\[\[([^\[\]|]+)(?:\|([^\[\]]+))?\]\]"#)
        guard let pattern else { return Text(s) }
        let ns = s as NSString
        var result = Text("")
        var last = 0
        for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                result = result + Text(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            }
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
    @State private var name = ""
    @State private var gist = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Brain").font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.foreground)
            VStack(alignment: .leading, spacing: 8) {
                field("Name", text: $name, placeholder: "Immunology")
                field("Description", text: $gist, placeholder: "What this vault is about")
            }
            if let errorText { Text(errorText).font(.system(size: 11)).foregroundStyle(Color(nsColor: Palette.agentDanger)) }
            HStack {
                Text("Creates ~/Geo/Brains/\(BrainVaultStore.slug(name.isEmpty ? "name" : name))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.tertiaryForeground)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(Palette.tertiaryForeground)
                Button("Create") { create() }.buttonStyle(PillButtonStyle()).disabled(trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Palette.background)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.tertiaryForeground)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13)).foregroundStyle(Palette.foreground)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Palette.agentCard)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border, lineWidth: 1))
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        do {
            let vault = try store.create(name: trimmed, gist: gist.trimmingCharacters(in: .whitespacesAndNewlines))
            _ = vault
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
