import SwiftUI

struct NanoTileModel: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
    let statusDot: Color?
    let isAdder: Bool
}

struct NanoTile: View {
    let model: NanoTileModel
    @State private var hovered = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(hovered ? 0.10 : 0.06))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    model.isAdder
                        ? Color.primary.opacity(0.20)
                        : Color.primary.opacity(0.12),
                    style: model.isAdder
                        ? StrokeStyle(lineWidth: 1, dash: [4, 3])
                        : StrokeStyle(lineWidth: 1)
                )
            content
                .padding(14)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if model.isAdder {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(model.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: model.icon)
                        .font(.system(size: 22))
                        .foregroundStyle(model.tint)
                    Spacer()
                    if let dot = model.statusDot {
                        Circle()
                            .fill(dot)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    }
                }
                Spacer()
                Text(model.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if let sub = model.subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
