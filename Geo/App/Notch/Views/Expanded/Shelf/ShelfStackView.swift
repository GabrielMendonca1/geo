import SwiftUI
import AppKit

struct ShelfStackView: View {
    let items: [ShelfItem]
    var onRemoveTop: () -> Void = {}
    var onClearAll: () -> Void = {}

    var body: some View {
        ZStack {
            if items.count > 2 {
                card(items[2])
                    .offset(x: 4, y: -4)
                    .rotationEffect(.degrees(3))
                    .scaleEffect(0.92)
            }
            if items.count > 1 {
                card(items[1])
                    .offset(x: -4, y: -2)
                    .rotationEffect(.degrees(-3))
                    .scaleEffect(0.96)
            }
            if let first = items.first {
                card(first)
            }
        }
        .overlay(alignment: .topLeading) { removeButton }
        .overlay(alignment: .topTrailing) { menuButton }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func card(_ item: ShelfItem) -> some View {
        Group {
            if let image = item.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Palette.border.opacity(0.15))
                    .frame(width: 160, height: 120)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: item.type.icon)
                                .font(.system(size: 28))
                                .foregroundStyle(Palette.tertiaryForeground)
                            Text(item.name)
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.tertiaryForeground)
                                .lineLimit(1)
                        }
                    )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Palette.border.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var removeButton: some View {
        Button(action: onRemoveTop) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.7))
                    .frame(width: 20, height: 20)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
            }
        }
        .buttonStyle(.plain)
        .padding(6)
    }

    private var menuButton: some View {
        Button(action: onClearAll) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.7))
                    .frame(width: 20, height: 20)
                Image(systemName: "ellipsis")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
            }
        }
        .buttonStyle(.plain)
        .padding(6)
    }
}
