import SwiftUI
import UIKit

extension Color {
    private static func adaptive(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { trait in
            let c = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    static let skyCanvas = adaptive((0x42 / 255, 0x61 / 255, 0x88 / 255), (0x0b / 255, 0x12 / 255, 0x20 / 255))
    static let skyCanvasLight = adaptive((0x5a / 255, 0x7b / 255, 0xa6 / 255), (0x17 / 255, 0x23 / 255, 0x3b / 255))
    static let actionBlue = adaptive((0x2b / 255, 0x7f / 255, 0xff / 255), (0x3b / 255, 0x8c / 255, 0xff / 255))
    static let cloudWhite = Color.white
    static let cardSurface = adaptive((1, 1, 1), (0x23 / 255, 0x2e / 255, 0x44 / 255))
    static let charcoalText = adaptive((0x1b / 255, 0x1b / 255, 0x1b / 255), (0xec / 255, 0xef / 255, 0xf4 / 255))
    static let hazeGrey = adaptive((0xf5 / 255, 0xf5 / 255, 0xf5 / 255), (0x23 / 255, 0x2c / 255, 0x3d / 255))
    static let midnightInk = Color.black
}

enum AirRadius {
    static let card: CGFloat = 14
    static let image: CGFloat = 11
    static let button: CGFloat = 8
    static let input: CGFloat = 4
}

enum AirSpacing {
    static let element: CGFloat = 8
    static let card: CGFloat = 20
    static let section: CGFloat = 48
}

struct SkyBackground: View {
    var body: some View {
        LinearGradient(
            colors: [.skyCanvasLight, .skyCanvas],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct AirCard: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: AirRadius.card, style: .continuous)
            )
    }
}

extension View {
    func airCard(padding: CGFloat = AirSpacing.card) -> some View {
        modifier(AirCard(padding: padding))
    }

    func skyScreen() -> some View {
        scrollContentBackground(.hidden)
            .background(SkyBackground())
    }

    func settingsToolbar() -> some View {
        modifier(SettingsToolbar())
    }
}

private struct SettingsToolbar: ViewModifier {
    @State private var showSettings = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
    }
}

struct AirStateCard: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(icon: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.actionBlue)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.charcoalText)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.charcoalText.opacity(0.55))
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(AirOutlineButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 300)
        .airCard(padding: 28)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyBackground())
    }
}

struct AirOutlineButtonStyle: ButtonStyle {
    var tint: Color = .actionBlue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .foregroundStyle(tint)
            .overlay(
                RoundedRectangle(cornerRadius: AirRadius.button, style: .continuous)
                    .stroke(tint, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

extension ButtonStyle where Self == AirOutlineButtonStyle {
    static var airOutline: AirOutlineButtonStyle { AirOutlineButtonStyle() }
}

enum AirAppearance {
    static func apply() {
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor(Color.cloudWhite)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(Color.cloudWhite)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(Color.cloudWhite)

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}
