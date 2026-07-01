import SwiftUI
import AppKit

// MARK: - Pane (Obsidian-style: sidebar · note editor tabs · local graph)

struct BrainsPane: View {
    @Environment(\.tabRouter) private var tabRouter
    @StateObject private var store = BrainVaultStore()
    @StateObject private var workspace = BrainWorkspaceModel()
    @State private var selectedVaultId: String?
    @State private var showCreate = false
    @State private var showSources = false
    @AppStorage("brains.sidebarWidth") private var sidebarWidth: Double = 264
    @AppStorage("brains.graphWidth") private var graphWidth: Double = 320

    private var selectedVault: BrainVault? {
        selectedVaultId.flatMap { id in store.vaults.first { $0.id == id } }
    }

    private var sidebarBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(sidebarWidth) }, set: { sidebarWidth = Double($0) })
    }
    private var graphBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(graphWidth) }, set: { graphWidth = Double($0) })
    }

    var body: some View {
        Pane {
            Group {
                if store.vaults.isEmpty {
                    emptyState
                } else {
                    ThreeColumnSplit(leftWidth: sidebarBinding, rightWidth: graphBinding) {
                        if let vault = selectedVault {
                            BrainSidebar(
                                store: store, workspace: workspace, tabs: workspace.tabs, vault: vault,
                                onSelectVault: { select($0) },
                                onNewNote: newNote,
                                onNewBrain: { showCreate = true },
                                onSources: { showSources = true }
                            )
                        }
                    } center: {
                        if let vault = selectedVault {
                            DocTabsView(
                                model: workspace.tabs,
                                onWikiLink: { workspace.openByTarget($0) },
                                onNew: newNote,
                                backlinks: { workspace.backlinkCount(for: $0) },
                                emptyState: AnyView(centerEmptyState(vault))
                            )
                        }
                    } right: {
                        BrainGraphPanel(workspace: workspace, tabs: workspace.tabs)
                    }
                }
            }
        }
        .task { store.reload() }
        .onChange(of: tabRouter.selectedTab) { _, tab in if tab == .brains { store.reload() } }
        .onChange(of: store.vaults.map(\.id)) { _, ids in syncSelection(ids) }
        .task(id: selectedVaultId) { await rebuildVault() }
        .onDisappear { workspace.flushAll() }
        .sheet(isPresented: $showCreate) {
            CreateBrainSheet(store: store) { newId in
                selectedVaultId = newId
                showCreate = false
            }
        }
        .sheet(isPresented: $showSources) {
            if let vault = selectedVault {
                BrainSourcesSheet(vault: vault, onBack: {
                    showSources = false
                    store.reload()
                    Task { await rebuildVault() }
                })
            }
        }
    }

    private func select(_ id: String) { selectedVaultId = id }

    private func syncSelection(_ ids: [String]) {
        if let id = selectedVaultId, ids.contains(id) { return }
        selectedVaultId = ids.first
    }

    private func rebuildVault() async {
        guard let vault = selectedVault else { return }
        workspace.setVault(vault)
        let result = await Task.detached { () -> ([BrainNote], BlockGraph, [UUID: BrainNote]) in
            let notes = BrainVaultStore.notes(in: vault)
            let built = BrainGraphBuilder.build(notes: notes)
            return (notes, built.graph, built.lookup)
        }.value
        guard selectedVaultId == vault.id else { return }
        workspace.loadNotes(result.0, graph: result.1, lookup: result.2)
    }

    private func newNote() {
        guard let vault = selectedVault, let id = try? store.createNote(in: vault) else { return }
        Task {
            await rebuildVault()
            workspace.open(id)
        }
    }

    // Center placeholder when no note tab is open: empty brain → steer to Sources; else → pick a note.
    @ViewBuilder private func centerEmptyState(_ vault: BrainVault) -> some View {
        if workspace.notes.isEmpty {
            VStack(spacing: 13) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 42, weight: .thin))
                    .foregroundStyle(Palette.tertiaryForeground.opacity(0.5))
                Text("This brain is empty").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text("Add sources — files, links, docs — and Geo distills them into linked notes.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.tertiaryForeground)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
                Button { showSources = true } label: { Label("Add sources", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle()).padding(.top, 2)
                Button { newNote() } label: {
                    Text("…or write a note yourself").font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground)
                }.buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text").font(.system(size: 40, weight: .thin))
                    .foregroundStyle(Palette.tertiaryForeground.opacity(0.5))
                Text("Select a note").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text("Pick a note from the sidebar, or create a new one.")
                    .font(.system(size: 12)).foregroundStyle(Palette.tertiaryForeground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
