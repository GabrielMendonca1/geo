import SwiftUI
import AppKit
import CoreText

enum FontManager {
    private enum FontName {
        static let monaSansRegular = "MonaSans-Regular"
        static let monaSansMedium = "MonaSans-Medium"
        static let monaSansSemiBold = "MonaSans-SemiBold"
        static let geistMonoRegular = "GeistMono-Regular"
        static let geistMonoMedium = "GeistMono-Medium"
    }

    static func monaSans(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name = monaSansFontName(for: weight)
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func geistMono(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        lineHeightScale: CGFloat = 1.0
    ) -> NSFont {
        let name = geistMonoFontName(for: weight)
        let baseFont: NSFont
        if let font = NSFont(name: name, size: size) {
            baseFont = font
        } else {
            baseFont = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }

        guard lineHeightScale > 0, lineHeightScale != 1 else {
            return baseFont
        }

        var matrix = CGAffineTransform(scaleX: 1.0, y: lineHeightScale)
        guard let scaledFont = CTFontCreateCopyWithAttributes(baseFont as CTFont, size, &matrix, nil) as NSFont? else {
            return baseFont
        }
        return scaledFont
    }

    static func monaSansFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = monaSansFontName(for: weight)
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight)
    }

    static func geistMonoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = geistMonoFontName(for: weight)
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    private static func monaSansFontName(for weight: NSFont.Weight) -> String {
        if weight.rawValue >= NSFont.Weight.semibold.rawValue {
            return FontName.monaSansSemiBold
        }
        if weight.rawValue >= NSFont.Weight.medium.rawValue {
            return FontName.monaSansMedium
        }
        return FontName.monaSansRegular
    }

    private static func monaSansFontName(for weight: Font.Weight) -> String {
        switch weight {
        case .semibold, .bold, .heavy, .black:
            return FontName.monaSansSemiBold
        case .medium:
            return FontName.monaSansMedium
        default:
            return FontName.monaSansRegular
        }
    }

    private static func geistMonoFontName(for weight: NSFont.Weight) -> String {
        if weight.rawValue >= NSFont.Weight.medium.rawValue {
            return FontName.geistMonoMedium
        }
        return FontName.geistMonoRegular
    }

    private static func geistMonoFontName(for weight: Font.Weight) -> String {
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black:
            return FontName.geistMonoMedium
        default:
            return FontName.geistMonoRegular
        }
    }
}
