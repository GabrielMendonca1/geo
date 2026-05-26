import SwiftUI
import AppKit

struct ShelfColumnView: View {
    @ObservedObject private var store = ShelfStore.shared
    @State private var showGrid: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                emptyState
            } else if showGrid {
                gridMode
            } else {
                stackMode
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.tertiaryForeground.opacity(0.5))
            Text("Drop files here")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.tertiaryForeground)
            Spacer()
        }
    }

    private var stackMode: some View {
        VStack(spacing: 10) {
            ShelfStackView(
                items: store.items,
                onRemoveTop: removeTop,
                onClearAll: clearAll
            )

            Button(action: { showGrid = true }) {
                Text("\(store.items.count) Items ▾")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.tertiaryForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Palette.border.opacity(0.2))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
    }

    private var gridMode: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("SHELF")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Palette.tertiaryForeground)
                Spacer()
                Button("Clear") { clearAll() }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.tertiaryForeground.opacity(0.7))
                    .buttonStyle(.plain)
                Button(action: { showGrid = false }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.tertiaryForeground.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 48), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(store.items) { item in
                        ZStack(alignment: .topTrailing) {
                            thumbnail(item)
                            Button(action: { store.removeItem(item) }) {
                                ZStack {
                                    Circle()
                                        .fill(Color.black)
                                        .frame(width: 12, height: 12)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundStyle(Palette.foreground)
                                }
                            }
                            .buttonStyle(.plain)
                            .offset(x: 3, y: -3)
                        }
                        .onDrag { makeDragProvider(for: item) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ item: ShelfItem) -> some View {
        Group {
            if let image = item.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Palette.border.opacity(0.15))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: item.type.icon)
                            .font(.system(size: 18))
                            .foregroundStyle(Palette.tertiaryForeground)
                    )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Palette.border.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func removeTop() {
        guard let first = store.items.first else { return }
        store.removeItem(first)
    }

    private func clearAll() {
        store.clearAll()
        showGrid = false
    }

    private func makeDragProvider(for item: ShelfItem) -> NSItemProvider {
        switch item.type {
        case .file, .folder, .image:
            let p = NSItemProvider()
            if let url = item.url {
                p.registerFileRepresentation(forTypeIdentifier: "public.file-url", fileOptions: [], visibility: .all) { c in
                    c(url, false, nil)
                    return nil
                }
            }
            return p
        case .webImage:
            guard let img = item.image else { return NSItemProvider() }
            return NSItemProvider(object: img)
        }
    }
}
