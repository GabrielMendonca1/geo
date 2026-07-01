import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - PaneTabBar — browser-style tab strip for a single pane (open notes · the graph)

struct PaneTab: Identifiable, Equatable {
    let id: String
    let title: String
    var icon: String? = nil
}

struct PaneTabBar: View {
    let tabs: [PaneTab]
    let activeId: String?
    var onSelect: (String) -> Void
    var onClose: ((String) -> Void)? = nil
    var onAdd: (() -> Void)? = nil
    var onReorder: ((Int, Int) -> Void)? = nil

    @State private var draggingId: String?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        chip(tab)
                        Rectangle().fill(Palette.border).frame(width: 1, height: 16)
                    }
                    if let onAdd {
                        AddTabButton(action: onAdd)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 38)
        .background(Color(nsColor: Palette.agentSurface))
    }

    @ViewBuilder
    private func chip(_ tab: PaneTab) -> some View {
        let view = TabChip(
            tab: tab,
            active: tab.id == activeId,
            dimmed: draggingId == tab.id,
            onSelect: { onSelect(tab.id) },
            onClose: onClose.map { close in { close(tab.id) } }
        )
        if let onReorder {
            view
                .onDrag {
                    draggingId = tab.id
                    return NSItemProvider(object: tab.id as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: TabReorderDropDelegate(
                        targetId: tab.id,
                        tabs: tabs,
                        draggingId: $draggingId,
                        onReorder: onReorder
                    )
                )
        } else {
            view
        }
    }
}

private struct TabReorderDropDelegate: DropDelegate {
    let targetId: String
    let tabs: [PaneTab]
    @Binding var draggingId: String?
    let onReorder: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragId = draggingId, dragId != targetId,
              let from = tabs.firstIndex(where: { $0.id == dragId }),
              let to = tabs.firstIndex(where: { $0.id == targetId }) else { return }
        onReorder(from, to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }
}

private struct TabChip: View {
    let tab: PaneTab
    let active: Bool
    var dimmed: Bool = false
    let onSelect: () -> Void
    let onClose: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            if let icon = tab.icon {
                Image(systemName: icon).font(.system(size: 11))
                    .foregroundStyle(active ? Palette.foreground.opacity(0.7) : Palette.tertiaryForeground)
            }
            Text(tab.title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Palette.foreground : Palette.tertiaryForeground)
                .lineLimit(1)
                .frame(maxWidth: 190, alignment: .leading)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hover ? Palette.foreground : Palette.tertiaryForeground)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(hover ? Palette.foreground.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(active || hover ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(active ? Palette.background : (hover ? Palette.foreground.opacity(0.04) : Color.clear))
        .contentShape(Rectangle())
        .opacity(dimmed ? 0.35 : 1)
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
    }
}

private struct AddTabButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover ? Palette.foreground : Palette.tertiaryForeground)
                .frame(width: 30, height: 38)
                .background(hover ? Palette.foreground.opacity(0.04) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("New note").onHover { hover = $0 }
    }
}
