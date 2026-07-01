import SwiftUI
import AppKit

// MARK: - Sources (custom back button + in-view actions; no .toolbar)

struct BrainSourcesSheet: View {
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
                HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)); Text("Brainsets").font(.system(size: 13)) }
                    .foregroundStyle(Palette.tertiaryForeground)
                    .contentShape(Rectangle())
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
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
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
