import SwiftUI
import UIKit

enum SlatePalette {
    static let canvas = dynamic(dark: gray(0x00), light: gray(0xFF))
    static let card = dynamic(dark: gray(0x1C), light: rgb(0xF2, 0xF2, 0xF7))
    static let elevated = dynamic(dark: gray(0x2C), light: rgb(0xE5, 0xE5, 0xEA))
    static let text = dynamic(dark: gray(0xFF), light: gray(0x00))
    static let textDim = text.withAlphaComponent(0.55)
    static let textFaint = text.withAlphaComponent(0.38)
    static let stroke = text.withAlphaComponent(0.28)

    static func ink(_ opacity: CGFloat) -> UIColor {
        text.withAlphaComponent(opacity)
    }

    private static func dynamic(dark: UIColor, light: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    private static func gray(_ value: Int) -> UIColor {
        rgb(value, value, value)
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

extension Color {
    static let cloudWhite = Color(SlatePalette.text)

    static let slateCanvas = Color(SlatePalette.canvas)
    static let slateCard = Color(SlatePalette.card)
    static let slateElevated = Color(SlatePalette.elevated)
    static let slateText = Color(SlatePalette.text)
    static let slateTextDim = Color(SlatePalette.textDim)
    static let slateTextFaint = Color(SlatePalette.textFaint)
    static let slateStroke = Color(SlatePalette.stroke)

    static func slateInk(_ opacity: CGFloat) -> Color {
        Color(SlatePalette.ink(opacity))
    }
}

enum AirRadius {
    static let card: CGFloat = 14
    static let image: CGFloat = 11
    static let button: CGFloat = 8
    static let input: CGFloat = 4
}

enum SlateRadius {
    static let card: CGFloat = 20
    static let cell: CGFloat = 12
}

struct GlassChrome<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}

struct SheetBackground: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.slateStroke.opacity(0.6), lineWidth: 0.5))
        }
    }
}

extension View {
    func glassSurface(shape: some Shape, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive))
    }

    func glassSheet(detents: Set<PresentationDetent> = [.medium]) -> some View {
        presentationDetents(detents)
            .presentationBackground { SheetBackground() }
            .presentationDragIndicator(.visible)
    }
}

enum AirSpacing {
    static let element: CGFloat = 8
    static let card: CGFloat = 20
    static let section: CGFloat = 48
}

extension View {
    func settingsToolbar() -> some View {
        modifier(SettingsToolbar())
    }
}

private struct SettingsToolbar: ViewModifier {
    @State private var showSettings = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                settingsToolbarItem
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
    }

    @ToolbarContentBuilder
    private var settingsToolbarItem: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) {
                settingsButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                settingsButton
            }
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .foregroundStyle(Color.slateTextDim)
        }
    }
}

enum AirAppearance {
    static func apply() {
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = SlatePalette.canvas
        nav.titleTextAttributes = [.foregroundColor: SlatePalette.text]
        nav.largeTitleTextAttributes = [.foregroundColor: SlatePalette.text]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = SlatePalette.text

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = SlatePalette.canvas
        let tabItemAppearance = UITabBarItemAppearance()
        tabItemAppearance.selected.iconColor = SlatePalette.text
        tabItemAppearance.normal.iconColor = SlatePalette.ink(0.4)
        tab.stackedLayoutAppearance = tabItemAppearance
        tab.inlineLayoutAppearance = tabItemAppearance
        tab.compactInlineLayoutAppearance = tabItemAppearance
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().tintColor = SlatePalette.text
    }
}
