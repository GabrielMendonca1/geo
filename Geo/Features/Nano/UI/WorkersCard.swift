import AppKit
import SwiftUI

struct WorkersCard: View {
    @StateObject private var service = HermesKanbanService()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if let err = service.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .onAppear { service.start() }
        .onDisappear { service.stop() }
    }

    private var header: some View {
        HStack {
            Text("Workers")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if active.count > 0 {
                Text("\(active.count) running")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
            }
            Spacer()
            if !service.dbAvailable {
                Text("hermes kanban.db not found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if service.tasks.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !active.isEmpty {
                    section(title: "Active", tint: .green, tasks: active)
                }
                if !queued.isEmpty {
                    section(title: "Queued", tint: .orange, tasks: queued)
                }
                if !recent.isEmpty {
                    section(title: "Recent", tint: .secondary, tasks: recent)
                }
            }
        }
    }

    private var emptyState: some View {
        Text("No workers active. Dispatch one with `claude_code_run(directory:, prompt:)` from hermes, or `hermes kanban create --assignee claude-code …`.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func section(title: String, tint: Color, tasks: [HermesKanbanService.KanbanTask]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(tasks.count)")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.7))
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tasks) { task in
                    WorkerRow(task: task, tint: tint)
                }
            }
        }
    }

    private var active: [HermesKanbanService.KanbanTask] { service.tasks.filter(\.isActive) }
    private var queued: [HermesKanbanService.KanbanTask] { service.tasks.filter(\.isQueued) }
    private var recent: [HermesKanbanService.KanbanTask] {
        service.tasks
            .filter(\.isRecent)
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
            .prefix(10)
            .map { $0 }
    }
}

private struct WorkerRow: View {
    let task: HermesKanbanService.KanbanTask
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(task.displayAssignee)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Spacer()
                    Text(ageString)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                HStack(spacing: 6) {
                    if let ws = task.workspaceShortPath {
                        Label(ws, systemImage: "folder")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .onTapGesture { revealInFinder() }
                            .help(task.workspacePath ?? "")
                    }
                    if let last = task.lastEventKind {
                        Text("· \(last)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                if task.isRecent, let result = task.result, !result.isEmpty {
                    Text(result)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var statusIcon: some View {
        Group {
            switch task.status {
            case "running":
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)
            case "done":
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 11))
            case "blocked":
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red.opacity(0.8))
                    .font(.system(size: 11))
            case "ready":
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
            default:
                Image(systemName: "circle")
                    .foregroundStyle(tint)
                    .font(.system(size: 11))
            }
        }
        .frame(width: 14, alignment: .center)
        .padding(.top, 1)
    }

    private var ageString: String {
        let anchor: Date
        switch task.status {
        case "running": anchor = task.startedAt ?? task.createdAt
        case "done", "blocked": anchor = task.completedAt ?? task.createdAt
        default: anchor = task.createdAt
        }
        let secs = Int(Date().timeIntervalSince(anchor))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }

    private func revealInFinder() {
        guard let path = task.workspacePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
