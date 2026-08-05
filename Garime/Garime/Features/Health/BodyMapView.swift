import CoreGraphics
import SwiftUI
import UIKit

struct BodyMapView: View {
    let highlighted: Set<String>

    var body: some View {
        HStack(spacing: 4) {
            BodySideView(shape: BodyShapes.front, highlighted: highlighted)
            BodySideView(shape: BodyShapes.back, highlighted: highlighted)
        }
    }
}

private struct BodySideView: View {
    let shape: BodyShape
    let highlighted: Set<String>

    var body: some View {
        GeometryReader { geometry in
            let box = shape.bounds
            let scale = min(geometry.size.width / box.width, geometry.size.height / box.height)
            let offsetX = (geometry.size.width - box.width * scale) / 2
            let offsetY = (geometry.size.height - box.height * scale) / 2

            ZStack {
                ForEach(shape.parts.indices, id: \.self) { index in
                    let part = shape.parts[index]
                    part.path
                        .applying(
                            CGAffineTransform(translationX: -box.minX, y: -box.minY)
                                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                                .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
                        )
                        .fill(color(for: part.slug))
                }
            }
        }
        .aspectRatio(shape.bounds.width / shape.bounds.height, contentMode: .fit)
    }

    private func color(for slug: String) -> Color {
        if highlighted.contains(slug) { return BodyMapPalette.highlight }
        if slug == "head" { return BodyMapPalette.head }
        return BodyMapPalette.body
    }
}

enum BodyMapPalette {
    static let body = Color.slateElevated
    static let head = Color.slateInk(0.28)
    static let highlight = Color(
        UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.60, blue: 0.97, alpha: 1)
            : UIColor(red: 0.24, green: 0.45, blue: 0.90, alpha: 1)
        }
    )
}

struct BodyPart {
    let slug: String
    let path: Path
}

struct BodyShape {
    let parts: [BodyPart]
    let bounds: CGRect
}

enum BodyShapes {
    static let front = make(BodyPaths.bodyFront)
    static let back = make(BodyPaths.bodyBack)

    private static func make(_ data: [BodyPathData]) -> BodyShape {
        var parts: [BodyPart] = []
        var bounds = CGRect.null
        for item in data {
            let cgPath = SVGPath.cgPath(from: item.d)
            let box = cgPath.boundingBoxOfPath
            if !box.isNull, !box.isInfinite {
                bounds = bounds.union(box)
            }
            parts.append(BodyPart(slug: item.slug, path: Path(cgPath)))
        }
        return BodyShape(parts: parts, bounds: bounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds)
    }
}

#Preview {
    VStack {
        BodyMapView(highlighted: ["chest", "triceps", "deltoids"])
            .frame(height: 320)
            .padding()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.slateCanvas)
}
