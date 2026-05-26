import SwiftUI

struct ResponsiveLayout {
    let scale: CGFloat
    let titleFontSize: CGFloat
    let editorFontSize: CGFloat
    let editorPaddingHorizontal: CGFloat
    let editorPaddingVertical: CGFloat
    let editorVStackSpacing: CGFloat

    init(windowSize: CGSize) {
        let baseSize = GeoStyle.Layout.baseEditorWindowSize
        let widthScale = windowSize.width > 0 ? windowSize.width / baseSize.width : 1
        let heightScale = windowSize.height > 0 ? windowSize.height / baseSize.height : 1

        let easedFontScale: CGFloat
        if widthScale >= 1 {
            easedFontScale = 1 + CGFloat(pow(Double(widthScale - 1), 1.1))
        } else {
            easedFontScale = 1 - CGFloat(pow(Double(1 - widthScale), 1.1))
        }
        let fontScale = min(max(easedFontScale, 0.9), 1.15)
        let paddingHorizontalScale = min(max(widthScale, 0.85), 1.2)
        let paddingVerticalScale = min(max(heightScale, 0.9), 1.15)
        let boost = GeoStyle.Layout.tasksPaneScaleBoost
        let boostedFontScale = min(max(fontScale * boost, 0.92), 1.2)
        let boostedPaddingHorizontalScale = min(max(paddingHorizontalScale * boost, 0.9), 1.24)
        let boostedPaddingVerticalScale = min(max(paddingVerticalScale * boost, 0.95), 1.2)

        scale = boostedFontScale
        titleFontSize = GeoStyle.Typography.titleFontSize * boostedFontScale
        editorFontSize = GeoStyle.Typography.editorFontSize * boostedFontScale
        editorPaddingHorizontal = GeoStyle.Spacing.editorPaddingHorizontal * boostedPaddingHorizontalScale
        editorPaddingVertical = GeoStyle.Spacing.editorPaddingVertical * boostedPaddingVerticalScale
        editorVStackSpacing = GeoStyle.Spacing.editorVStackSpacing * boostedFontScale
    }
}

private struct ViewSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension View {
    func readSize(onChange: @escaping @MainActor (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ViewSizePreferenceKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(ViewSizePreferenceKey.self) { newSize in
            Task { @MainActor in onChange(newSize) }
        }
    }
}
