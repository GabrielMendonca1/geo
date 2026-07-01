import SwiftUI
import AppKit

// MARK: - Sidebar — sources + search · note list · vault switcher

struct BrainSidebar: View {
    @ObservedObject var store: BrainVaultStore
    @ObservedObject var workspace: BrainWorkspaceModel
    @ObservedObject var tabs: DocTabsModel
    let vault: BrainVault
    let onSelectVault: (String) -> Void
    let onNewNote: () -> Void
    let onNewBrain: () -> Void
    let onSources: () -> Void

    @State private var search = ""

    private var filtered: [BrainNote] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return workspace.notes }
        return workspace.notes.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Palette.border).frame(height: 1)
            searchField
            Rectangle().fill(Palette.border).frame(height: 1)
            notesList
            Rectangle().fill(Palette.border).frame(height: 1)
            footer
        }
        .background(Color(nsColor: Palette.agentSurface))
    }

    // Sources is the primary "feed the brain" action — files / links the agent distills into notes.
    private var topBar: some View {
        HStack(spacing: 6) {
            Button { onSources() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full").font(.system(size: 11, weight: .medium))
                    Text("Sources").font(.system(size: 12, weight: .semibold))
                    if vault.sourceCount > 0 {
                        Text("\(vault.sourceCount)").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Palette.foreground.opacity(0.10)))
                    }
                }
                .foregroundStyle(Palette.foreground)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Palette.foreground.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Add files, links and docs — Geo distills them into linked notes")

            Spacer(minLength: 0)

            IconButton(system: "square.and.pencil", help: "New note") { onNewNote() }
            IconButton(system: "folder", help: "Reveal vault in Finder") { NSWorkspace.shared.open(vault.folder) }
        }
        .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 7)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.tertiaryForeground)
            TextField("Search notes", text: $search)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Palette.foreground)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.tertiaryForeground)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    @ViewBuilder private var notesList: some View {
        if filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: search.isEmpty ? "doc.text" : "magnifyingglass")
                    .font(.system(size: 22, weight: .thin)).foregroundStyle(Palette.tertiaryForeground.opacity(0.5))
                Text(search.isEmpty ? "No notes yet" : "No matches")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.tertiaryForeground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { note in
                        NoteRow(note: note, active: note.id == tabs.activeId) {
                            workspace.open(note.id)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(store.vaults) { v in
                    Button {
                        onSelectVault(v.id)
                    } label: {
                        Label(v.title, systemImage: v.id == vault.id ? "checkmark" : "brain.head.profile")
                    }
                }
                Divider()
                Button { onNewBrain() } label: { Label("New Brain…", systemImage: "plus") }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(vault.ready ? Color(nsColor: Palette.agentSuccess) : Palette.tertiaryForeground)
                        .frame(width: 7, height: 7)
                    Text(vault.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.foreground).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.tertiaryForeground)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

private struct NoteRow: View {
    let note: BrainNote
    let active: Bool
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                Image(systemName: "doc.text").font(.system(size: 12))
                    .foregroundStyle(active ? Palette.foreground : Palette.tertiaryForeground)
                Text(note.title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Palette.foreground : Palette.foreground.opacity(0.85))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(rowFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }

    private var rowFill: Color {
        if active { return Palette.foreground.opacity(0.10) }
        if hover { return Palette.foreground.opacity(0.05) }
        return .clear
    }
}
