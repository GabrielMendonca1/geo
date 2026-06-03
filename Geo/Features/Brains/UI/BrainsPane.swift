import SwiftUI
import UniformTypeIdentifiers

extension BlockIndexEntry: Identifiable {}

struct BrainsPane: View {
    @State private var brains: [BrainManifest] = []
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(brains) { brain in
                    NavigationLink {
                        BrainDetailView(brainId: brain.id)
                    } label: {
                        BrainRow(brain: brain)
                    }
                }
            }
            .navigationTitle("Brains")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreate = true } label: { Label("New Brain", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateBrainSheet { reload() }
            }
            .task { reload() }
        }
    }

    private func reload() {
        brains = BrainRegistry.shared.list()
    }
}

private struct BrainRow: View {
    let brain: BrainManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(brain.title).font(.headline)
                if brain.kind == .essence {
                    Text("personal").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(brain.ingestState.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            if !brain.gist.isEmpty {
                Text(brain.gist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("\(brain.nodeCount) notes · \(brain.sourceCount) sources").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private struct CreateBrainSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorText: String?
    let onCreated: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Brain").font(.title3.bold())
            TextField("Name (e.g. Immunology)", text: $name).textFieldStyle(.roundedBorder)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        let id = WikiTitleNormalizer.normalize(trimmed).replacingOccurrences(of: " ", with: "-")
        guard !id.isEmpty else { errorText = "Invalid name"; return }
        do {
            _ = try BrainRegistry.shared.createBrain(id: id, title: trimmed)
            onCreated()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct BrainDetailView: View {
    let brainId: String
    @State private var manifest: BrainManifest?
    @State private var nodes: [BlockIndexEntry] = []
    @State private var showImporter = false
    @State private var ingesting = false
    @State private var mode: DetailMode = .notes
    @State private var graphSelection: BlockIndexEntry?
    @StateObject private var brainGraph = BrainGraphStore()

    private enum DetailMode: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case graph = "Graph"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(DetailMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Group {
                switch mode {
                case .notes: notesList
                case .graph: graphArea
                }
            }
        }
        .navigationTitle(manifest?.title ?? brainId)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Label("Attach Sources", systemImage: "paperclip") }
                    .disabled(ingesting)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .plainText, .text, .html], allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .overlay {
            if ingesting {
                ProgressView("Ingesting…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(item: $graphSelection) { node in
            NavigationStack { BrainNodeView(node: node) }
                .frame(minWidth: 480, minHeight: 360)
        }
        .task {
            reload()
            await brainGraph.load(brainId: brainId)
        }
    }

    private var notesList: some View {
        List {
            if let manifest {
                Section("Status") {
                    Text(manifest.ingestState.rawValue.capitalized)
                    if let lastError = manifest.lastError {
                        Text(lastError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Section("\(nodes.count) notes") {
                ForEach(nodes, id: \.id) { node in
                    NavigationLink {
                        BrainNodeView(node: node)
                    } label: {
                        Text(node.title.isEmpty ? node.id : node.title)
                    }
                }
            }
        }
    }

    private var graphArea: some View {
        GraphView(
            graph: brainGraph.graph,
            seedPositions: brainGraph.cachedPositions,
            wasSettled: brainGraph.simulationSettled,
            sidebarHidden: true,
            onLayoutChange: { positions, settled in
                brainGraph.updateLayoutCache(positions: positions, settled: settled)
            },
            isActive: { true }
        ) { id in
            if let blockId = brainGraph.idLookup[id], let node = nodes.first(where: { $0.id == blockId }) {
                graphSelection = node
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        manifest = BrainRegistry.shared.manifest(brainId)
        Task {
            guard let index = BrainRegistry.shared.index(for: brainId) else { return }
            let loaded = (try? await index.listByType("literature")) ?? []
            await MainActor.run { nodes = loaded }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        ingesting = true
        Task {
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try? BrainRegistry.shared.addSource(from: url, toBrain: brainId)
            }
            let pipeline = IngestPipeline(brainId: brainId)
            var step: BrainIngestStep = .pending
            var iterations = 0
            repeat {
                step = (try? await pipeline.advance()) ?? .failed
                iterations += 1
            } while step != .ready && step != .failed && iterations < 12
            await MainActor.run {
                ingesting = false
                reload()
            }
        }
    }
}

private struct BrainNodeView: View {
    let node: BlockIndexEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(node.title.isEmpty ? node.id : node.title).font(.title2.bold())
                Text(node.content).textSelection(.enabled)
                Label("Read-only · domain brain", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(node.title.isEmpty ? node.id : node.title)
    }
}
