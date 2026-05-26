import AppKit
import SwiftUI

enum Palette {
    static let background: Color = Color(light: .white, dark: .black)
    static var windowBackground: NSColor { NSColor(background) }
    static let secondaryBackground: Color = Color(light: Color(white: 0.97), dark: Color(white: 0.06))
    static let foreground: Color = Color(light: .black, dark: .white)
    static let tertiaryForeground: Color = Color(light: Color(white: 0.45), dark: Color(white: 0.55))
    static let border: Color = Color(light: Color(white: 0.88), dark: Color(white: 0.14))
    static let accent: Color = Color(light: .black, dark: .white)
    static let accentDark: Color = .white

    static let editorForeground: NSColor = adaptive(
        light: NSColor.black,
        dark: NSColor.white
    )

    static let terminalBackground: NSColor = adaptive(
        light: NSColor.white,
        dark: NSColor.black
    )
    static let terminalForeground: NSColor = adaptive(
        light: NSColor.black,
        dark: NSColor.white
    )
    static let terminalCaret: NSColor = adaptive(
        light: NSColor.black,
        dark: NSColor.white
    )
    static let terminalSelection: NSColor = adaptive(
        light: NSColor(white: 0.0, alpha: 0.18),
        dark: NSColor(white: 1.0, alpha: 0.22)
    )

    static let agentSurface: NSColor = adaptive(
        light: NSColor(white: 0.98, alpha: 0.92),
        dark: NSColor(white: 0.04, alpha: 0.92)
    )
    static let agentCard: NSColor = adaptive(
        light: NSColor(white: 1.0, alpha: 0.88),
        dark: NSColor(white: 0.07, alpha: 0.88)
    )
    static let agentCardElevated: NSColor = adaptive(
        light: NSColor(white: 1.0, alpha: 0.96),
        dark: NSColor(white: 0.10, alpha: 0.96)
    )
    static let agentBorder: NSColor = adaptive(
        light: NSColor(white: 0.0, alpha: 0.10),
        dark: NSColor(white: 1.0, alpha: 0.10)
    )
    static let agentMutedText: NSColor = adaptive(
        light: NSColor(white: 0.45, alpha: 1.0),
        dark: NSColor(white: 0.60, alpha: 1.0)
    )
    static let agentAccent: NSColor = adaptive(
        light: NSColor.black,
        dark: NSColor.white
    )
    static let agentSuccess: NSColor = adaptive(
        light: NSColor(red: 0.11, green: 0.55, blue: 0.30, alpha: 1.0),
        dark: NSColor(red: 0.42, green: 0.82, blue: 0.50, alpha: 1.0)
    )
    static let agentWarning: NSColor = adaptive(
        light: NSColor(red: 0.78, green: 0.52, blue: 0.10, alpha: 1.0),
        dark: NSColor(red: 0.96, green: 0.74, blue: 0.30, alpha: 1.0)
    )
    static let agentDanger: NSColor = adaptive(
        light: NSColor(red: 0.78, green: 0.20, blue: 0.22, alpha: 1.0),
        dark: NSColor(red: 1.0, green: 0.48, blue: 0.48, alpha: 1.0)
    )

    static let agentAnsiLight: [NSColor] = monoAnsiLight
    static let agentAnsiDark: [NSColor] = monoAnsiDark
}

private func adaptive(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return dark
        default: return light
        }
    }
}

private let monoAnsiLight: [NSColor] = [
    NSColor(white: 0.00, alpha: 1.0),
    NSColor(red: 0.72, green: 0.16, blue: 0.18, alpha: 1.0),
    NSColor(red: 0.10, green: 0.52, blue: 0.24, alpha: 1.0),
    NSColor(red: 0.65, green: 0.46, blue: 0.06, alpha: 1.0),
    NSColor(white: 0.20, alpha: 1.0),
    NSColor(red: 0.46, green: 0.28, blue: 0.78, alpha: 1.0),
    NSColor(white: 0.30, alpha: 1.0),
    NSColor(white: 0.40, alpha: 1.0),
    NSColor(white: 0.55, alpha: 1.0),
    NSColor(red: 0.86, green: 0.30, blue: 0.30, alpha: 1.0),
    NSColor(red: 0.30, green: 0.70, blue: 0.40, alpha: 1.0),
    NSColor(red: 0.86, green: 0.62, blue: 0.16, alpha: 1.0),
    NSColor(white: 0.10, alpha: 1.0),
    NSColor(red: 0.62, green: 0.40, blue: 0.90, alpha: 1.0),
    NSColor(white: 0.25, alpha: 1.0),
    NSColor(white: 0.00, alpha: 1.0)
]

private let monoAnsiDark: [NSColor] = [
    NSColor(white: 0.00, alpha: 1.0),
    NSColor(red: 0.96, green: 0.44, blue: 0.40, alpha: 1.0),
    NSColor(red: 0.46, green: 0.84, blue: 0.50, alpha: 1.0),
    NSColor(red: 0.90, green: 0.72, blue: 0.32, alpha: 1.0),
    NSColor(white: 0.85, alpha: 1.0),
    NSColor(red: 0.74, green: 0.56, blue: 0.96, alpha: 1.0),
    NSColor(white: 0.75, alpha: 1.0),
    NSColor(white: 0.85, alpha: 1.0),
    NSColor(white: 0.55, alpha: 1.0),
    NSColor(red: 1.00, green: 0.58, blue: 0.54, alpha: 1.0),
    NSColor(red: 0.54, green: 0.92, blue: 0.58, alpha: 1.0),
    NSColor(red: 0.96, green: 0.80, blue: 0.42, alpha: 1.0),
    NSColor(white: 0.95, alpha: 1.0),
    NSColor(red: 0.84, green: 0.72, blue: 1.00, alpha: 1.0),
    NSColor(white: 0.80, alpha: 1.0),
    NSColor(white: 1.00, alpha: 1.0)
]
