import CoreGraphics

enum EditorTypographyPreferences {
    static let fontSizeKey = "editor.typography.fontSize"

    static let defaultSize: Double = 13
    static let minSize: Double = 11
    static let maxSize: Double = 22
    static let step: Double = 1

    static func clampedSize(_ value: Double) -> Double {
        min(max(value, minSize), maxSize)
    }

    static func clampedSize(_ value: CGFloat) -> CGFloat {
        CGFloat(clampedSize(Double(value)))
    }
}
