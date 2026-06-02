import SwiftUI
import AppKit

struct TitleBarOverlay: View {
    let navigationStore: NavigationStore

    var body: some View {
        VStack(spacing: 0) {
            chromeStrip
            Spacer(minLength: 0)
        }
    }

    private var chromeStrip: some View {
        HStack(spacing: 8) {
            TrafficLightsView()
                .padding(.trailing, 8)
            TitleBarNavigationTabs(tabRouter: navigationStore.tabRouter)
            TitleBarSettingsButton()
            Spacer()
            TitleBarLogoView()
                .padding(.trailing, 14)
        }
        .frame(height: TitleBarMetrics.stripHeight)
        .liquidGlassChrome()
    }
}

struct TitleBarBlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    @ViewBuilder
    func liquidGlassChrome() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: Rectangle())
        } else {
            self.background(TitleBarBlurBackground())
        }
    }
}
