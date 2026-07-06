import SwiftUI

struct AgentsView: View {
    @StateObject private var viewModel = AgentsViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.dispatches.isEmpty, viewModel.errorMessage != nil {
                    errorState
                } else if viewModel.dispatches.isEmpty, viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(SkyBackground())
                } else if viewModel.dispatches.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Agents")
            .settingsToolbar()
            .navigationDestination(for: DispatchItem.self) { dispatch in
                DispatchDetailView(dispatch: dispatch, viewModel: viewModel)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        TerminalScreen()
                    } label: {
                        Image(systemName: "terminal")
                    }
                }
            }
        }
        .task { await viewModel.autoRefresh() }
    }

    private var list: some View {
        List(viewModel.dispatches) { dispatch in
            NavigationLink(value: dispatch) {
                row(for: dispatch)
            }
            .listRowBackground(Color.cardSurface)
        }
        .listStyle(.insetGrouped)
        .skyScreen()
        .refreshable { await viewModel.reload() }
    }

    private func row(for dispatch: DispatchItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dispatch.meta.title)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(dispatch.status)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(statusColor(dispatch.status))
                    .background(statusColor(dispatch.status).opacity(0.15), in: Capsule())
                if let started = dispatch.meta.startedDate {
                    Text(started.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "running": return .actionBlue
        case "done": return .green
        case "failed": return .red
        default: return .gray
        }
    }

    private var emptyState: some View {
        AirStateCard(
            icon: "cpu",
            title: "No agents",
            message: "Claude workers dispatched from your Mac will appear here."
        )
    }

    private var errorState: some View {
        AirStateCard(
            icon: "wifi.exclamationmark",
            title: "Can't reach the bridge",
            message: viewModel.errorMessage ?? "",
            actionTitle: "Retry",
            action: { Task { await viewModel.reload() } }
        )
    }
}

struct DispatchDetailView: View {
    let dispatch: DispatchItem
    @ObservedObject var viewModel: AgentsViewModel
    @State private var autoScroll = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.events) { event in
                        EventRow(event: event)
                    }
                    if let error = viewModel.streamError {
                        Text(error)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                    if let status = viewModel.streamStatus {
                        Text("— \(status) —")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color(white: 0.5))
                            .frame(maxWidth: .infinity)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.08))
            .simultaneousGesture(
                DragGesture().onChanged { value in
                    if value.translation.height > 0 {
                        autoScroll = false
                    }
                }
            )
            .onChange(of: viewModel.events.count) {
                if autoScroll {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: autoScroll) {
                if autoScroll {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .navigationTitle(dispatch.meta.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    autoScroll.toggle()
                } label: {
                    Image(systemName: autoScroll ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line.circle")
                }
            }
        }
        .task { await viewModel.streamDetail(id: dispatch.id) }
    }
}

private struct EventRow: View {
    let event: AgentEvent

    var body: some View {
        switch event.kind {
        case .assistant:
            Text(event.text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Color(white: 0.92))
                .textSelection(.enabled)
        case .tool:
            Text("› \(event.text)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.cyan)
                .lineLimit(1)
        case .result:
            VStack(alignment: .leading, spacing: 4) {
                if let detail = event.detail {
                    Text(detail)
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(event.isError ? .red : .green)
                }
                if !event.text.isEmpty {
                    Text(event.text)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Color(white: 0.75))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .raw:
            Text(event.text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
                .lineLimit(3)
        }
    }
}

#Preview {
    AgentsView()
}
