import SwiftUI
import AppKit

struct MainView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.navigationStore) private var navigationStore
    @State private var window: NSWindow?
    @State private var commandPalette = CommandPaletteViewModel()

    var body: some View {
        ZStack(alignment: .top) {
            Palette.background
                .padding(.top, TitleBarMetrics.stripHeight)

            NavigationChrome()
                .frame(minWidth: 600, minHeight: 400)
                .padding(.top, TitleBarMetrics.stripHeight)

            TitleBarOverlay(navigationStore: navigationStore)

            CommandPaletteOverlay(viewModel: commandPalette)
        }
        .ignoresSafeArea()
        .clipShape(RoundedRectangle(cornerRadius: GeoStyle.Layout.windowCornerRadius, style: .continuous))
        .geoWindowChrome(window: $window)
        .onAppear {
            Task { @MainActor in
                appEnvironment.settingsRepository.refreshPermissions()
            }
        }
        .background {
            ZStack {
                Button("") { commandPalette.toggle() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        navigationStore.fabExpanded.toggle()
                    }
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            .hidden()
        }
    }

}

private struct NavigationChrome: View {
    @Environment(\.navigationStore) private var navigationStore

    var body: some View {
        UnifiedNavigationContainer()
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
            .environment(\.navigationStore, NavigationStore())
            .environment(\.appEnvironment, AppContainer.live.environment)
    }
}
