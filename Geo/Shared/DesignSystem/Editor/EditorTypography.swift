import AppKit

enum EditorTypography {

    private struct FontKey: Hashable {
        let kind: KindTag
        let baseSize: CGFloat
    }

    private enum KindTag: Hashable {
        case heading(Int)
        case codeBlock
        case body
    }

    private static var fontCache: [FontKey: NSFont] = [:]

    static func fontForKind(_ kind: EditorBlockKind, baseSize: CGFloat) -> NSFont {
        let tag: KindTag
        switch kind {
        case .heading(let level): tag = .heading(level)
        case .codeBlock: tag = .codeBlock
        default: tag = .body
        }
        let key = FontKey(kind: tag, baseSize: baseSize)
        if let cached = fontCache[key] { return cached }
        let font: NSFont
        switch tag {
        case .heading(let level):
            let scales: [CGFloat] = [1.75, 1.45, 1.2, 1.05, 0.95, 0.9]
            let scale = scales[min(level - 1, 5)]
            font = FontManager.geistMono(size: baseSize * scale, weight: .bold)
        case .codeBlock:
            font = FontManager.geistMono(size: baseSize * 0.9)
        case .body:
            font = FontManager.geistMono(size: baseSize)
        }
        fontCache[key] = font
        return font
    }

    static func lineHeightForKind(_ kind: EditorBlockKind) -> CGFloat {
        switch kind {
        case .heading:
            return 1.2
        default:
            return 1.3
        }
    }

    static func invalidateCache() {
        fontCache.removeAll()
    }
}
