import SwiftUI

// MARK: - Right pane — the local graph of the active note (note + direct neighbors)

struct BrainGraphPanel: View {
    @ObservedObject var workspace: BrainWorkspaceModel
    @ObservedObject var tabs: DocTabsModel
    @Environment(\.tabRouter) private var tabRouter

    // Active note + its 1-hop neighborhood (cached adjacency); full vault graph when nothing is open.
    private var displayedGraph: BlockGraph {
        guard let note = workspace.activeNote else { return workspace.graph }
        let local = workspace.localSubgraph(around: note)
        return local.nodes.isEmpty ? workspace.graph : local
    }

    private var tabTitle: String {
        if let note = workspace.activeNote { return "Graph of \(note.title)" }
        return "Graph"
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneTabBar(
                tabs: [PaneTab(id: "graph", title: tabTitle, icon: "point.3.connected.trianglepath.dotted")],
                activeId: "graph",
                onSelect: { _ in }
            )
            Rectangle().fill(Palette.border).frame(height: 1)
            if displayedGraph.nodes.isEmpty {
                emptyState
            } else {
                GraphView(
                    graph: displayedGraph,
                    isActive: { [tabRouter] in tabRouter.selectedTab == .brains },
                    persistsSettings: false,
                    initialFitScale: 0.5,
                    maxInitialZoom: 0.8,
                    minZoom: 0.15
                ) { nodeId in
                    if let note = workspace.lookup[nodeId] { workspace.open(note.id) }
                }
                .id(tabs.activeId ?? "__all__")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .thin)).foregroundStyle(Palette.tertiaryForeground.opacity(0.5))
            Text("No links yet").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.tertiaryForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
