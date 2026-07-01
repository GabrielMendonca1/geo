import SwiftUI
import AppKit

// MARK: - Reusable controls (shared across the Brains feature)

struct IconButton: View {
    let system: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 13))
                .foregroundStyle(hover ? Palette.foreground : Palette.tertiaryForeground)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Palette.foreground.opacity(0.08) : .clear))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Palette.foreground.opacity(configuration.isPressed ? 0.82 : 1)))
            .foregroundStyle(Palette.background)
            .contentShape(Capsule())
    }
}

// A kind glyph inside a soft tinted chip — shared by source rows and add tiles.
struct SourceBadge: View {
    let kind: BrainSourceKind
    var size: CGFloat = 40
    var corner: CGFloat = 10
    var glyph: CGFloat = 18

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(kind.tint.opacity(0.14))
            Image(systemName: kind.icon).font(.system(size: glyph, weight: .regular)).foregroundStyle(kind.tint)
        }
        .frame(width: size, height: size)
    }
}

struct RebuildButton: View {
    var spinning: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover ? Palette.foreground : Palette.tertiaryForeground)
                .rotationEffect(.degrees(angle))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Palette.foreground.opacity(0.08) : .clear))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Rebuild notes from sources").onHover { hover = $0 }
        .onChange(of: spinning) { _, on in
            if on { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 } }
            else { withAnimation(.easeOut(duration: 0.2)) { angle = 0 } }
        }
    }
}

struct SourceFileRow: View {
    let url: URL
    @State private var hover = false
    private var kind: BrainSourceKind { BrainSourceKind.of(url.pathExtension) }

    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            HStack(spacing: 10) {
                SourceBadge(kind: kind, size: 30, corner: 8, glyph: 13)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.foreground)
                        .lineLimit(1).truncationMode(.middle)
                    Text(kind.displayName.uppercased())
                        .font(.system(size: 9, weight: .medium)).tracking(0.4)
                        .foregroundStyle(Palette.tertiaryForeground)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiaryForeground)
                    .opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Palette.foreground.opacity(0.05) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(hover ? Palette.border : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Reveal in Finder").onHover { hover = $0 }
    }
}

struct AddTile: View {
    let kind: BrainSourceKind
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 11) {
                SourceBadge(kind: kind, size: 46, corner: 12, glyph: 21)
                    .scaleEffect(hover ? 1.06 : 1)
                Text(kind.displayName)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.foreground)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity).frame(height: 112)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: hover ? Palette.agentCardElevated : Palette.agentCard)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover ? kind.tint.opacity(0.45) : Palette.foreground.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(hover ? 0.10 : 0.04), radius: hover ? 8 : 3, y: hover ? 3 : 1)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.background)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Palette.foreground))
                    .padding(7).opacity(hover ? 1 : 0).scaleEffect(hover ? 1 : 0.6)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.03 : 1)
        .animation(.easeOut(duration: 0.14), value: hover)
        .onHover { hover = $0 }
    }
}
